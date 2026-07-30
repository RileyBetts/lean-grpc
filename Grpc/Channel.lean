/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Grpc.Client
import Grpc.Status
import Grpc.Message
import Grpc.Metadata

namespace Grpc

/-- Client channel with connection reuse. -/
structure Channel where
  host : String
  port : UInt16
  conn : IO.Ref (Option H2.ClientConn)
  maxMsgSize : Nat := 4 * 1024 * 1024

namespace Channel

def connectH2c (host : String) (port : UInt16) : IO Channel := do
  let c ← H2.Client.connectH2c host port
  let r ← IO.mkRef (some c)
  return { host, port, conn := r }

def get (ch : Channel) : IO H2.ClientConn := do
  match ← ch.conn.get with
  | some c => return c
  | none =>
    let c ← H2.Client.connectH2c ch.host ch.port
    ch.conn.set (some c)
    return c

def unary (ch : Channel) (service method : String) (request : ByteArray)
    (metadata : Metadata := {}) (timeout? : Option String := none) : IO CallResult := do
  if request.size > ch.maxMsgSize then
    return { status := .resourceExhausted "message too large", message := ByteArray.empty,
             headers := #[], trailers := #[] }
  let c ← get ch
  let mut extra := Metadata.toFields metadata
  if let some t := timeout? then
    extra := extra.push (Metadata.timeout t)
  Client.unaryCall c service method ch.host request extra

def close (ch : Channel) : IO Unit := do
  ch.conn.set none

end Channel
end Grpc
