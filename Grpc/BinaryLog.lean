/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Hpack
import Grpc.Status
import Grpc.Metadata
import Grpc.Server
import Grpc.Channel

namespace Grpc.BinaryLog

/-- Coarse `grpc.binlog.v1.GrpcLogEntry.EventType` subset: enough to reconstruct the shape of
    a call (headers in both directions, messages in both directions, trailers). -/
inductive EventKind where
  | clientHeader | serverHeader | clientMessage | serverMessage | serverTrailer | cancel
  deriving BEq, Inhabited, Repr

structure Event where
  kind : EventKind
  callId : Nat := 0
  timestampMs : Nat := 0
  headers : Array Hpack.HeaderField := #[]
  payload : ByteArray := ByteArray.empty
  status : Option Status := none
  deriving Inhabited

/-- Append-only in-memory sink (a real binary logger would flush `Event`s to a file/collector;
    this keeps them in an `IO.Ref` array so tests/tools can inspect exactly what was logged). -/
abbrev Sink := IO.Ref (Array Event)

def newSink : IO Sink := IO.mkRef #[]

def logEvent (sink : Sink) (kind : EventKind) (callId : Nat) (headers : Array Hpack.HeaderField := #[])
    (payload : ByteArray := ByteArray.empty) (status : Option Status := none) : IO Unit := do
  let t ← IO.monoMsNow
  sink.modify (·.push { kind, callId, timestampMs := t, headers, payload, status })

def events (sink : Sink) : IO (Array Event) := sink.get

def clear (sink : Sink) : IO Unit := sink.set #[]

/-- Number of logged events matching `kind`. -/
def countOf (sink : Sink) (kind : EventKind) : IO Nat := do
  return (← sink.get).foldl (fun n e => if e.kind == kind then n + 1 else n) 0

/-- Wrap a unary client call, logging the full client-header → client-message →
    server-header → server-message → server-trailer sequence for it. -/
def logUnaryCall (sink : Sink) (callId : Nat) (ch : Channel) (service method : String)
    (request : ByteArray) (metadata : Metadata := {}) : IO CallResult := do
  logEvent sink .clientHeader callId (headers := Metadata.toFields metadata)
  logEvent sink .clientMessage callId (payload := request)
  let res ← Channel.unary ch service method request metadata
  logEvent sink .serverHeader callId (headers := res.headers)
  logEvent sink .serverMessage callId (payload := res.message)
  logEvent sink .serverTrailer callId (headers := res.trailers) (status := some res.status)
  return res

/-- Wrap a unary server handler with client-message/server-message/server-trailer logging. -/
def logUnaryHandler (sink : Sink) (callId : Nat) (h : UnaryHandler) : UnaryHandler := fun req => do
  logEvent sink .clientMessage callId (payload := req)
  let (resp, st) ← h req
  logEvent sink .serverMessage callId (payload := resp)
  logEvent sink .serverTrailer callId (status := some st)
  return (resp, st)

end Grpc.BinaryLog
