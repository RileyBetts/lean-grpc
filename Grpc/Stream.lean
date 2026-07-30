/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Pool
import Bytes.Slice
import Bytes.BE
import H2
import Hpack
import Grpc.Status
import Grpc.Message
import Grpc.Metadata

namespace Grpc.Stream

/- Real streaming helpers over multiplexed HTTP/2 DATA frames. -/

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
  o.buf.modify (·.push (Message.encodeId msg))

def Outgoing.close (o : Outgoing) : IO Unit :=
  o.closed.set true

/-- Concatenate length-prefixed messages. -/
def collectServerStream (msgs : Array ByteArray) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for m in msgs do
      out := Bytes.Pool.pushBytes out m
    return out

def Outgoing.take (o : Outgoing) : IO ByteArray := do
  let msgs ← o.buf.modifyGet fun a => (a, #[])
  return collectServerStream msgs

/-- Split a DATA buffer into complete gRPC messages; returns messages + remainder. -/
def decodeAvailable (buf : ByteArray) : Except String (Array ByteArray × ByteArray) := do
  let mut s := Bytes.Slice.ofByteArray buf
  let mut out : Array ByteArray := #[]
  while s.size ≥ 5 do
    let len ← Bytes.BE.readU32 s 1 |>.elim (throw "len") pure
    let total := 5 + len.toNat
    if s.size < total then break
    let (p, rest) ← Message.decodeOne s
    out := out.push p
    s := rest
  return (out, s.toByteArray)

/-- Server-streaming style: one request message → many response messages (buffered). -/
structure ServerStreamCall where
  request : ByteArray
  responses : Array ByteArray
  status : Status := {}
  deriving Inhabited

/-- Client-streaming style: many request messages → one response. -/
structure ClientStreamCall where
  requests : Array ByteArray
  response : ByteArray
  status : Status := {}
  deriving Inhabited

/-- Bidi: pairs of request batches to response batches (buffered end-to-end). -/
structure BidiCall where
  requests : Array ByteArray
  responses : Array ByteArray
  status : Status := {}
  deriving Inhabited

end Grpc.Stream
