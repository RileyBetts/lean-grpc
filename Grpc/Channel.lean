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

namespace Channel

def connectH2c (host : String) (port : UInt16) : IO Channel := do
  let c ← H2.Client.connectH2c host port
  let r ← IO.mkRef (some c)
  let now ← IO.monoMsNow
  let act ← IO.mkRef now
  return { host, port, conn := r, lastActivityMs := act }

def get (ch : Channel) : IO H2.ClientConn := do
  match ← ch.conn.get with
  | some c =>
    -- Idle keepalive: send PING if quiet longer than keepaliveMs.
    if ch.keepaliveMs > 0 then
      let now ← IO.monoMsNow
      let last ← ch.lastActivityMs.get
      if now - last ≥ ch.keepaliveMs then
        H2.sendFrames c.sock #[H2.Frame.ping (ByteArray.mk #[1,2,3,4,5,6,7,8])]
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
  -- Enforce non-zero deadlines via sleep+cancel is not wired; reject already-expired
  -- and enforce positive deadlines by checking elapsed wall time around the call.
  let deadlineMs? :=
    match timeout? with
    | none => none
    | some t => Metadata.parseTimeoutMs t
  if let some 0 := deadlineMs? then
    return { status := .deadlineExceeded, message := ByteArray.empty, headers := #[], trailers := #[] }
  let c ← get ch
  let mut extra := Metadata.toFields metadata
  if let some t := timeout? then
    extra := extra.push (Metadata.timeout t)
  let t0 ← IO.monoMsNow
  let res ← Client.unaryCall c service method ch.host request extra compress
  let t1 ← IO.monoMsNow
  ch.lastActivityMs.set t1
  if let some ms := deadlineMs? then
    if t1 - t0 > ms then
      return { res with status := .deadlineExceeded }
  return res

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
