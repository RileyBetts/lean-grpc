/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Pool
import Grpc.Status
import Grpc.Message

namespace Grpc.Stream

/- Streaming helpers for server/client streaming over gRPC length-prefixed messages. -/

structure Incoming where
  messages : Array ByteArray
  deriving Inhabited

structure Outgoing where
  private mk ::
    buf : IO.Ref (Array ByteArray)
    closed : IO.Ref Bool

def Outgoing.new : IO Outgoing := do
  return ⟨← IO.mkRef #[], ← IO.mkRef false⟩

def Outgoing.send (o : Outgoing) (msg : ByteArray) : IO Unit := do
  if ← o.closed.get then throw (IO.userError "stream closed")
  o.buf.modify (·.push (Message.encode msg))

def Outgoing.close (o : Outgoing) : IO Unit :=
  o.closed.set true

/-- Server-streaming: one request, many responses encoded into a single DATA buffer. -/
def collectServerStream (msgs : Array ByteArray) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for m in msgs do
      out := Bytes.Pool.pushBytes out (Message.encode m)
    return out

end Grpc.Stream
