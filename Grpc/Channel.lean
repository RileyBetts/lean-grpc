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
import Grpc.XdsAds

namespace Grpc

/-- Client channel with connection reuse. -/
structure Channel where
  /-- `:authority` pseudo-header value (the original dial target, not necessarily
      the backend currently connected to under round_robin). -/
  host : String
  port : UInt16
  conn : IO.Ref (Option H2.ClientConn)
  /-- Backend address the pooled `conn` is (or should be) connected to. -/
  connAddr : IO.Ref Resolver.Address
  /-- Default max message size for both directions (used when the direction-specific
      field below is unset). -/
  maxMsgSize : Nat := 4 * 1024 * 1024
  /-- Max outbound (request) message size; falls back to `maxMsgSize` when `none`. -/
  maxSendMsgSize : Option Nat := none
  /-- Max inbound (response) message size; falls back to `maxMsgSize` when `none`. -/
  maxRecvMsgSize : Option Nat := none
  /-- Idle keepalive PING interval in milliseconds (0 = disabled). -/
  keepaliveMs : Nat := 30000
  lastActivityMs : IO.Ref Nat
  balancer : IO.Ref Balancer.State
  serviceConfig : ServiceConfig.Config := {}
  callCreds : Option Credentials.CallCredentials := none
  channelCreds : Credentials.ChannelCredentials := .insecure

namespace Channel

def sendMsgSize (ch : Channel) : Nat := ch.maxSendMsgSize.getD ch.maxMsgSize
def recvMsgSize (ch : Channel) : Nat := ch.maxRecvMsgSize.getD ch.maxMsgSize

private def connectAddr (host : String) (port : UInt16)
    (creds : Credentials.ChannelCredentials) : IO H2.ClientConn := do
  match creds with
  | .insecure => H2.Client.connectH2c host port
  | .tls cfg => Tls.connectH2 host port cfg

def connectH2c (host : String) (port : UInt16) : IO Channel := do
  let c ← H2.Client.connectH2c host port
  let r ← IO.mkRef (some c)
  let now ← IO.monoMsNow
  let act ← IO.mkRef now
  let bal ← IO.mkRef (Balancer.create .pickFirst #[{ host, port }])
  let addrRef ← IO.mkRef ({ host, port } : Resolver.Address)
  return { host, port, conn := r, connAddr := addrRef, lastActivityMs := act, balancer := bal }

/-- Dial via resolver + balancer (`dns:///host:port`, `host:port`, or `xds:///name`
    when `LEAN_GRPC_XDS_BOOTSTRAP` is set). -/
def dial (target : String) (opts : Credentials.DialOptions := {})
    (svc : ServiceConfig.Config := {}) : IO Channel := do
  let addrs ←
    if "xds:///".isPrefixOf target then XdsAds.resolveFromEnv target
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
  let c ← connectAddr addr.host addr.port opts.channel
  let r ← IO.mkRef (some c)
  let now ← IO.monoMsNow
  let act ← IO.mkRef now
  let balRef ← IO.mkRef bal
  let addrRef ← IO.mkRef addr
  return {
    host := opts.authority.getD addr.host
    port := addr.port
    conn := r
    connAddr := addrRef
    lastActivityMs := act
    balancer := balRef
    serviceConfig := svc
    callCreds := opts.call
    channelCreds := opts.channel
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
      H2.sendFrames c.transport (H2.goAwayFrames st)
      c.state.set { st with wentAway := true, pendingPing := ByteArray.empty, pendingPingAtMs := 0 }
      ch.conn.set none
      let addr ← ch.connAddr.get
      let c ← connectAddr addr.host addr.port ch.channelCreds
      ch.conn.set (some c)
      ch.lastActivityMs.set now
      return c
    if ch.keepaliveMs > 0 then
      let last ← ch.lastActivityMs.get
      if now - last ≥ ch.keepaliveMs && st.pendingPingAtMs == 0 then
        let payload := ByteArray.mk #[1,2,3,4,5,6,7,8]
        H2.sendFrames c.transport #[H2.Frame.ping payload]
        c.state.set { st with pendingPing := payload, pendingPingAtMs := now }
        ch.lastActivityMs.set now
    return c
  | none =>
    let addr ← ch.connAddr.get
    let c ← connectAddr addr.host addr.port ch.channelCreds
    ch.conn.set (some c)
    let now ← IO.monoMsNow
    ch.lastActivityMs.set now
    return c

/-- Consult the balancer for the next backend address (round_robin cycles through
    all resolved addresses; pick_first always returns the same one) and drop the
    pooled connection when it targets a different address, so the next `get`
    dials the newly-selected backend. Called once per unary attempt so
    `round_robin` actually spreads attempts across backends. -/
private def pickAndMaybeReconnect (ch : Channel) : IO Unit := do
  let bal ← ch.balancer.get
  let (addr?, bal') := Balancer.pick bal
  ch.balancer.set bal'
  match addr? with
  | none => pure ()
  | some addr =>
    let cur ← ch.connAddr.get
    if cur != addr then
      ch.conn.set none
      ch.connAddr.set addr

/-- If the pooled connection has seen (or been marked with) GOAWAY, drop it so
    this attempt reports UNAVAILABLE immediately instead of trying to open a new
    stream on a transport the peer is closing down. The *next* attempt
    (retry/hedge) dials a fresh connection via `get`. Calls already in flight
    hold their own `H2.ClientConn` reference directly and are unaffected — they
    run to completion independently of this channel's pooled connection. -/
private def checkGoAway (ch : Channel) : IO Bool := do
  match ← ch.conn.get with
  | none => pure false
  | some c =>
    let st ← c.state.get
    if st.wentAway then
      ch.conn.set none
      pure true
    else
      pure false

private def goAwayResult : CallResult :=
  { status := Status.unavailable "connection went away (GOAWAY)"
    message := ByteArray.empty, headers := #[], trailers := #[] }

private def enforceRecvSize (ch : Channel) (res : CallResult) : CallResult :=
  if res.status.code == .ok && res.message.size > ch.recvMsgSize then
    { res with status := Status.resourceExhausted "message too large" }
  else res

/-- A hedge attempt is "final" (safe to declare the race winner) once it succeeds
    or fails with a status hedging isn't configured to keep racing past. -/
private def isHedgeFinal (hedge : ServiceConfig.HedgingPolicy) (code : StatusCode) : Bool :=
  code == .ok || !(hedge.nonFatalStatusCodes.any (· == code.toUInt32))

/-- Parallel hedging: launch concurrent attempts (one immediately, further ones
    after `hedgingDelayMs` each, up to `maxAttempts`, unless a winner is already
    known), race them with an `IO.Promise`, and RST_STREAM every losing attempt
    still in flight once the first OK / first non-retriable terminal result (or
    the last-launched attempt, to guarantee progress) resolves the race. -/
private def raceHedge (ch : Channel) (service method : String) (request : ByteArray)
    (extra : Array Hpack.HeaderField) (compress : Compression.Algorithm)
    (hedge : ServiceConfig.HedgingPolicy) : IO CallResult := do
  let useHttps := match ch.channelCreds with | .tls _ => true | .insecure => false
  let winner ← IO.Promise.new (α := Nat × CallResult)
  let resolvedFlag ← IO.mkRef false
  let attempts ← IO.mkRef (#[] : Array (H2.ClientConn × UInt32))
  let resolveOnce (i : Nat) (r : CallResult) : IO Unit := do
    let already ← resolvedFlag.modifyGet (fun b => (b, true))
    if !already then winner.resolve (i, r)
  let spawnAttempt (i : Nat) : IO Unit := do
    pickAndMaybeReconnect ch
    if ← checkGoAway ch then
      resolveOnce i goAwayResult
    else
      let c ← get ch
      let (sid, dl?) ← Client.startUnary c service method ch.host request extra compress useHttps
      attempts.modify (·.push (c, sid))
      discard <| IO.asTask (prio := .dedicated) do
        try
          let r ← Client.finishUnary c sid dl?
          let r := enforceRecvSize ch r
          if isHedgeFinal hedge r.status.code || i + 1 ≥ hedge.maxAttempts then
            resolveOnce i r
        catch e =>
          if i + 1 ≥ hedge.maxAttempts then
            resolveOnce i { status := Status.unavailable (toString e), message := ByteArray.empty,
                            headers := #[], trailers := #[] }
  spawnAttempt 0
  for i in [1:hedge.maxAttempts] do
    if !(← resolvedFlag.get) then
      IO.sleep hedge.hedgingDelayMs.toUInt32
      if !(← resolvedFlag.get) then
        spawnAttempt i
  let result ←
    match ← IO.wait winner.result? with
    | some (winnerIdx, result) =>
      let finished ← attempts.get
      let mut idx := 0
      for (c, sid) in finished do
        if idx != winnerIdx then
          H2.Client.resetStream c sid 0x8
        idx := idx + 1
      pure result
    | none => pure goAwayResult
  ch.lastActivityMs.set (← IO.monoMsNow)
  return result

def unary (ch : Channel) (service method : String) (request : ByteArray)
    (metadata : Metadata := {}) (timeout? : Option String := none)
    (compress : Compression.Algorithm := .identity) : IO CallResult := do
  if request.size > ch.sendMsgSize then
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
  let mut extra := Metadata.toFields md
  if let some t := timeout? then
    extra := extra.push (Metadata.timeout t)
  else if let some ms := deadlineMs? then
    extra := extra.push (Metadata.timeout s!"{ms}m")
  match ch.serviceConfig.hedging with
  | some hedge => raceHedge ch service method request extra compress hedge
  | none =>
    let maxAttempts :=
      match ch.serviceConfig.retry with
      | some p => p.maxAttempts
      | none => 1
    let mut attempt : Nat := 0
    let mut last : CallResult :=
      { status := Status.unavailable "no attempt", message := ByteArray.empty, headers := #[], trailers := #[] }
    while attempt < maxAttempts do
      pickAndMaybeReconnect ch
      if ← checkGoAway ch then
        last := goAwayResult
      else
        let c ← get ch
        let t0 ← IO.monoMsNow
        let useHttps :=
          match ch.channelCreds with
          | .tls _ => true
          | .insecure => false
        let res ← Client.unaryCall c service method ch.host request extra compress useHttps
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
        last := enforceRecvSize ch res
        if last.status.code == .ok then return last
      match ch.serviceConfig.retry with
      | some policy =>
        if Retry.shouldRetry policy last.status.code attempt then
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
  let scheme :=
    match ch.channelCreds with
    | .tls _ => Metadata.schemeHttps
    | .insecure => Metadata.schemeHttp
  let headers : Array Hpack.HeaderField :=
    #[
      Metadata.methodPost,
      scheme,
      ⟨Metadata.ascii ":authority", Metadata.ascii ch.host⟩,
      Metadata.path service method,
      Metadata.contentTypeGrpc,
      Metadata.teTrailers,
      Metadata.userAgent,
      Metadata.grpcAcceptEncoding "identity,gzip,deflate,snappy"
    ] ++ Metadata.toFields metadata
  Stream.openCall c headers

/-- Send GOAWAY and drop the pooled connection (graceful drain from client side). -/
def goAway (ch : Channel) : IO Unit := do
  match ← ch.conn.get with
  | none => pure ()
  | some c =>
    let st ← c.state.get
    H2.sendFrames c.transport (H2.goAwayFrames st)
    ch.conn.set none

def close (ch : Channel) : IO Unit := do
  ch.conn.set none

end Channel
end Grpc
