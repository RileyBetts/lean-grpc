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

/-- Concatenate already length-prefixed gRPC frames. -/
def collectServerStream (msgs : Array ByteArray) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for m in msgs do
      out := Bytes.Pool.pushBytes out m
    return out

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

/-! # Public streaming API (client) -/

structure StreamWriter where
  conn : H2.ClientConn
  streamId : UInt32
  closed : IO.Ref Bool

structure StreamReader where
  conn : H2.ClientConn
  streamId : UInt32
  pending : IO.Ref ByteArray
  /-- Bytes of connection `dataBuf` already copied into `pending`. -/
  dataSeen : IO.Ref Nat
  headers : IO.Ref (Option (Array Hpack.HeaderField))
  trailers : IO.Ref (Option (Array Hpack.HeaderField))
  done : IO.Ref Bool

structure ClientStream where
  writer : StreamWriter
  reader : StreamReader

namespace StreamWriter

def send (w : StreamWriter) (msg : ByteArray) : IO Unit := do
  if ← w.closed.get then throw (IO.userError "stream closed")
  let st ← w.conn.state.get
  -- Best-effort: wait briefly if connection send window is exhausted.
  let mut spins : Nat := 0
  while st.sendConnWindow ≤ 0 && spins < 50 do
    spins := spins + 1
    IO.sleep 1
  H2.sendFrames w.conn.transport (H2.Frame.dataFragmented w.streamId (Message.encodeId msg) false
    st.ourSettings.maxFrameSize.toNat)

def halfClose (w : StreamWriter) : IO Unit := do
  if ← w.closed.get then return
  w.closed.set true
  H2.sendFrames w.conn.transport #[H2.Frame.data w.streamId ByteArray.empty true]

end StreamWriter

namespace StreamReader

/-- Pump connection until headers are available. -/
partial def ensureHeaders (r : StreamReader) (fuel : Nat := 200) : IO (Array Hpack.HeaderField) := do
  if let some h ← r.headers.get then return h
  if fuel == 0 then throw (IO.userError "timeout waiting headers")
  match ← r.conn.state.get >>= (fun st => pure (st.getStream r.streamId)) with
  | none => pure ()
  | some s =>
    if s.endHeaders then
      r.headers.set (some s.requestHeaders)
      return s.requestHeaders
  match (← r.conn.transport.recv? 65536) with
  | none => throw (IO.userError "EOF")
  | some chunk =>
    let mut buf ← r.conn.readBuf.get
    buf := Bytes.Pool.pushBytes buf chunk
    let st0 ← r.conn.state.get
    let (frames, consumed) ← IO.ofExcept
      (H2.decodeFrames (Bytes.Slice.ofByteArray buf) st0.ourSettings.maxFrameSize.toNat)
    r.conn.readBuf.set (buf.extract consumed buf.size)
    let mut st := st0
    for f in frames do
      let (st', outs) ← IO.ofExcept (H2.handleFrame st f)
      st := st'
      H2.sendFrames r.conn.transport outs
    r.conn.state.set st
    ensureHeaders r (fuel - 1)

/-- Receive next message, or `none` when remote half-closes (trailers available). -/
partial def recv? (r : StreamReader) (fuel : Nat := 200) : IO (Option ByteArray) := do
  if ← r.done.get then return none
  discard <| ensureHeaders r
  let pend ← r.pending.get
  match decodeAvailable pend with
  | .error e => throw (IO.userError e)
  | .ok (msgs, rest) =>
    if msgs.size > 0 then
      r.pending.set rest
      -- Return first; push remainder back by re-encoding... keep simple: only one at a time
      let mut left := ByteArray.empty
      for i in [1:msgs.size] do
        left := Bytes.Pool.pushBytes left (Message.encodeId msgs[i]!)
      r.pending.set (Bytes.Pool.pushBytes left rest)
      return some msgs[0]!
    let st ← r.conn.state.get
    if let some s := st.getStream r.streamId then
      let seen ← r.dataSeen.get
      if s.dataBuf.size > seen then
        let fresh := s.dataBuf.extract seen s.dataBuf.size
        r.pending.set (Bytes.Pool.pushBytes pend fresh)
        r.dataSeen.set s.dataBuf.size
        return (← recv? r fuel)
      if s.endStreamRemote then
        r.trailers.set (some s.decodedTrailers)
        r.done.set true
        return none
    if fuel == 0 then throw (IO.userError "timeout waiting message")
    match (← r.conn.transport.recv? 65536) with
    | none =>
      r.done.set true
      return none
    | some chunk =>
      let mut buf ← r.conn.readBuf.get
      buf := Bytes.Pool.pushBytes buf chunk
      let st0 ← r.conn.state.get
      let (frames, consumed) ← IO.ofExcept
        (H2.decodeFrames (Bytes.Slice.ofByteArray buf) st0.ourSettings.maxFrameSize.toNat)
      r.conn.readBuf.set (buf.extract consumed buf.size)
      let mut st := st0
      for f in frames do
        let (st', outs) ← IO.ofExcept (H2.handleFrame st f)
        st := st'
        H2.sendFrames r.conn.transport outs
      r.conn.state.set st
      recv? r (fuel - 1)

def getTrailers (r : StreamReader) : IO (Array Hpack.HeaderField) := do
  discard <| recv? r  -- drain
  return (← r.trailers.get).getD #[]

end StreamReader

/-- Open a client streaming call (headers sent, stream open for send/recv). -/
def openCall (c : H2.ClientConn) (headers : Array Hpack.HeaderField) : IO ClientStream := do
  let sid ← H2.Client.startRequest c headers ByteArray.empty false
  let closed ← IO.mkRef false
  let pending ← IO.mkRef ByteArray.empty
  let dataSeen ← IO.mkRef 0
  let hdrs ← IO.mkRef none
  let tr ← IO.mkRef none
  let done ← IO.mkRef false
  return {
    writer := { conn := c, streamId := sid, closed }
    reader := { conn := c, streamId := sid, pending, dataSeen, headers := hdrs, trailers := tr, done }
  }

/-! # Server-side streaming handler types -/

/-- Server streaming handler: one request → many response messages. -/
abbrev ServerStreamHandler := ByteArray → IO (Array ByteArray × Status)

/-- Client streaming handler: many requests → one response. -/
abbrev ClientStreamHandler := Array ByteArray → IO (ByteArray × Status)

/-- Bidi handler: many requests → many responses (buffered batch for now). -/
abbrev BidiStreamHandler := Array ByteArray → IO (Array ByteArray × Status)

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

def Outgoing.take (o : Outgoing) : IO ByteArray := do
  let msgs ← o.buf.modifyGet fun a => (a, #[])
  return collectServerStream msgs

end Grpc.Stream
