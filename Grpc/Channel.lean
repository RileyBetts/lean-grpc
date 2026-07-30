/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Hpack
import Grpc.Client
import Grpc.Status
import Grpc.Message
import Grpc.Metadata
import Grpc.Stream
import Grpc.Compression
import Grpc.Resolver
import Grpc.Balancer
import Grpc.Credentials
import Grpc.Tls
import Grpc.ServiceConfig
import Grpc.Retry
import Grpc.Xds

namespace Grpc

/-- Client channel with connection reuse. -/
structure Channel where
  host : String
  port : UInt16
  conn : IO.Ref (Option H2.ClientConn)
  maxMsgSize : Nat := 4 * 1024 * 1024
  /-- Idle keepalive PING interval in milliseconds (0 = disabled). -/
  keepaliveMs : Nat := 30000
  lastActivityMs : IO.Ref Nat
  balancer : IO.Ref Balancer.State
  serviceConfig : ServiceConfig.Config := {}
  callCreds : Option Credentials.CallCredentials := none

namespace Channel

def connectH2c (host : String) (port : UInt16) : IO Channel := do
  let c ← H2.Client.connectH2c host port
  let r ← IO.mkRef (some c)
  let now ← IO.monoMsNow
  let act ← IO.mkRef now
  let bal ← IO.mkRef (Balancer.create .pickFirst #[{ host, port }])
  return { host, port, conn := r, lastActivityMs := act, balancer := bal }

/-- Dial via resolver + balancer (`dns:///host:port`, `host:port`, or `xds:///name`
    when `LEAN_GRPC_XDS_BOOTSTRAP` is set). -/
def dial (target : String) (opts : Credentials.DialOptions := {})
    (svc : ServiceConfig.Config := {}) : IO Channel := do
  let addrs ←
    if "xds:///".isPrefixOf target then Xds.resolveFromEnv target
    else Resolver.resolve target
  let policy :=
    if svc.loadBalancingPolicy == "round_robin" then Balancer.Policy.roundRobin
    else Balancer.Policy.pickFirst
  let bal0 := Balancer.create policy addrs
  let (addr?, bal) := Balancer.pick bal0
  let addr ←
    match addr? with
    | some a => pure a
    | none => throw (IO.userError "no addresses")
  let c ←
    match opts.channel with
    | .insecure => H2.Client.connectH2c addr.host addr.port
    | .tls cfg => Tls.connectH2 addr.host addr.port cfg
  let r ← IO.mkRef (some c)
  let now ← IO.monoMsNow
  let act ← IO.mkRef now
  let balRef ← IO.mkRef bal
  return {
    host := opts.authority.getD addr.host
    port := addr.port
    conn := r
    lastActivityMs := act
    balancer := balRef
    serviceConfig := svc
    callCreds := opts.call
  }

/-- Max wait for PING ACK before GOAWAY (Phase 9 keepalive enforcement). -/
def pingTimeoutMs : Nat := 20000

def get (ch : Channel) : IO H2.ClientConn := do
  match ← ch.conn.get with
  | some c =>
    let now ← IO.monoMsNow
    let st ← c.state.get
    -- Keepalive enforcement: unanswered PING → GOAWAY and drop connection.
    if st.pendingPingAtMs != 0 && now - st.pendingPingAtMs ≥ pingTimeoutMs then
      H2.sendFrames c.sock (H2.goAwayFrames st)
      c.state.set { st with wentAway := true, pendingPing := ByteArray.empty, pendingPingAtMs := 0 }
      ch.conn.set none
      let c ← H2.Client.connectH2c ch.host ch.port
      ch.conn.set (some c)
      ch.lastActivityMs.set now
      return c
    if ch.keepaliveMs > 0 then
      let last ← ch.lastActivityMs.get
      if now - last ≥ ch.keepaliveMs && st.pendingPingAtMs == 0 then
        let payload := ByteArray.mk #[1,2,3,4,5,6,7,8]
        H2.sendFrames c.sock #[H2.Frame.ping payload]
        c.state.set { st with pendingPing := payload, pendingPingAtMs := now }
        ch.lastActivityMs.set now
    return c
  | none =>
    let c ← H2.Client.connectH2c ch.host ch.port
    ch.conn.set (some c)
    let now ← IO.monoMsNow
    ch.lastActivityMs.set now
    return c

def unary (ch : Channel) (service method : String) (request : ByteArray)
    (metadata : Metadata := {}) (timeout? : Option String := none)
    (compress : Compression.Algorithm := .identity) : IO CallResult := do
  if request.size > ch.maxMsgSize then
    return { status := .resourceExhausted "message too large", message := ByteArray.empty,
             headers := #[], trailers := #[] }
  let deadlineMs? :=
    match timeout? with
    | some t => Metadata.parseTimeoutMs t
    | none => ch.serviceConfig.timeoutMs
  if let some 0 := deadlineMs? then
    return { status := .deadlineExceeded, message := ByteArray.empty, headers := #[], trailers := #[] }
  let mut md := metadata
  if let some creds := ch.callCreds then
    md ← creds.apply md
  let maxAttempts :=
    match ch.serviceConfig.hedging with
    | some h => h.maxAttempts
    | none =>
      match ch.serviceConfig.retry with
      | some p => p.maxAttempts
      | none => 1
  let mut attempt : Nat := 0
  let mut last : CallResult :=
    { status := Status.unavailable "no attempt", message := ByteArray.empty, headers := #[], trailers := #[] }
  while attempt < maxAttempts do
    let c ← get ch
    let mut extra := Metadata.toFields md
    if let some t := timeout? then
      extra := extra.push (Metadata.timeout t)
    else if let some ms := deadlineMs? then
      extra := extra.push (Metadata.timeout s!"{ms}m")
    let t0 ← IO.monoMsNow
    let res ← Client.unaryCall c service method ch.host request extra compress
    let t1 ← IO.monoMsNow
    ch.lastActivityMs.set t1
    -- Mid-RPC deadline already enforced in H2.Client.awaitResponse (RST + DEADLINE_EXCEEDED).
    -- Keep wall-clock overlay as a belt-and-suspenders for races.
    let res :=
      match deadlineMs? with
      | some ms =>
        if t1 - t0 ≥ ms || res.status.code == .deadlineExceeded then
          { res with status := Status.deadlineExceeded }
        else res
      | none => res
    last := res
    if res.status.code == .ok then return last
    match ch.serviceConfig.hedging with
    | some hedge =>
      if attempt + 1 < hedge.maxAttempts &&
          hedge.nonFatalStatusCodes.any (· == res.status.code.toUInt32) then
        IO.sleep hedge.hedgingDelayMs.toUInt32
        attempt := attempt + 1
      else
        return last
    | none =>
      match ch.serviceConfig.retry with
      | some policy =>
        if Retry.shouldRetry policy res.status.code attempt then
          IO.sleep (Retry.backoffMs policy attempt).toUInt32
          attempt := attempt + 1
        else
          return last
      | none =>
        return last
  return last

/-- Open a bidirectional client stream for `service/method`. -/
def openStream (ch : Channel) (service method : String)
    (metadata : Metadata := {}) : IO Stream.ClientStream := do
  let c ← get ch
  let headers : Array Hpack.HeaderField :=
    #[
      Metadata.methodPost,
      Metadata.schemeHttp,
      ⟨Metadata.ascii ":authority", Metadata.ascii ch.host⟩,
      Metadata.path service method,
      Metadata.contentTypeGrpc,
      Metadata.teTrailers,
      Metadata.grpcAcceptEncoding "identity,gzip"
    ] ++ Metadata.toFields metadata
  Stream.openCall c headers

/-- Send GOAWAY and drop the pooled connection (graceful drain from client side). -/
def goAway (ch : Channel) : IO Unit := do
  match ← ch.conn.get with
  | none => pure ()
  | some c =>
    let st ← c.state.get
    H2.sendFrames c.sock (H2.goAwayFrames st)
    ch.conn.set none

def close (ch : Channel) : IO Unit := do
  ch.conn.set none

end Channel
end Grpc
