/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std.Async.TCP
import Std.Net.Addr
import Bytes.Slice
import Bytes.Pool
import Hpack
import H2.Preface
import H2.Frame
import H2.Connection
import H2.Server

open Std.Async
open Std.Net

namespace H2

structure ClientConn where
  sock : TCP.Socket.Client
  state : IO.Ref ConnState
  readBuf : IO.Ref ByteArray

namespace Client

def connectH2c (host : String) (port : UInt16) : IO ClientConn := do
  let sock ← TCP.Socket.Client.mk
  let addr ←
    match IPv4Addr.ofString host with
    | some a => pure (SocketAddress.v4 { addr := a, port })
    | none => pure (SocketAddress.v4 { addr := IPv4Addr.ofParts 127 0 0 1, port })
  (sock.connect addr).block
  -- Client preface + SETTINGS
  (sock.send clientPreface).block
  let st := ConnState.create
  sendFrames sock #[Frame.settings #[
    (.initialWindowSize, st.ourSettings.initialWindowSize),
    (.maxFrameSize, st.ourSettings.maxFrameSize)
  ]]
  let state ← IO.mkRef st
  let readBuf ← IO.mkRef ByteArray.empty
  -- Read server SETTINGS (and ACK ours)
  let mut buf := ByteArray.empty
  let mut gotSettings := false
  for _ in [:20] do
    match (← (sock.recv? 65536).block) with
    | none => break
    | some chunk =>
      buf := Bytes.Pool.pushBytes buf chunk
      let (frames, consumed) ← IO.ofExcept (decodeFrames (Bytes.Slice.ofByteArray buf))
      buf := buf.extract consumed buf.size
      let mut st ← state.get
      for f in frames do
        let (st', outs) ← IO.ofExcept (handleFrame st f)
        st := st'
        sendFrames sock outs
        if f.type == .settings && !(Flags.has f.flags Flags.ack) then
          gotSettings := true
          sendFrames sock #[Frame.settingsAck]
      state.set st
      if gotSettings then break
  readBuf.set buf
  return { sock, state, readBuf }

/-- Start a new request stream; returns stream id. -/
def startRequest (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray)
    (endStream : Bool := true) : IO UInt32 := do
  let mut st ← c.state.get
  let sid := st.nextClientStreamId
  st := { st with nextClientStreamId := sid + 2 }
  let s := { Stream.create sid st.ourSettings.initialWindowSize with state := .open }
  st := st.upsertStream s
  c.state.set st
  let block := Hpack.encodeHeadersIndexed headers
  let endH := true
  sendFrames c.sock #[Frame.headers sid block (body.size == 0 && endStream) endH]
  if body.size > 0 then
    sendFrames c.sock (Frame.dataFragmented sid body endStream st.ourSettings.maxFrameSize.toNat)
  return sid

/-- Wait for response headers+data on a stream (simple polling read). -/
partial def awaitResponse (c : ClientConn) (streamId : UInt32) (fuel : Nat := 100) :
    IO (Array Hpack.HeaderField × ByteArray) := do
  if fuel == 0 then throw (IO.userError "timeout waiting response")
  let st ← c.state.get
  if let some s := st.getStream streamId then
    if s.endHeaders && s.endStreamRemote then
      match Hpack.decodeHeaders (Bytes.Slice.ofByteArray s.headersBuf) st.decoderTable with
      | .error e => throw (IO.userError e)
      | .ok (hdrs, table) =>
        c.state.set { st with decoderTable := table }
        return (hdrs, s.dataBuf)
  -- read more
  match (← (c.sock.recv? 65536).block) with
  | none => throw (IO.userError "EOF")
  | some chunk =>
    let mut buf ← c.readBuf.get
    buf := Bytes.Pool.pushBytes buf chunk
    let (frames, consumed) ← IO.ofExcept (decodeFrames (Bytes.Slice.ofByteArray buf))
    c.readBuf.set (buf.extract consumed buf.size)
    let mut st ← c.state.get
    for f in frames do
      let (st', outs) ← IO.ofExcept (handleFrame st f)
      st := st'
      sendFrames c.sock outs
    c.state.set st
    awaitResponse c streamId (fuel - 1)

def unary (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray) :
    IO (Array Hpack.HeaderField × ByteArray) := do
  let sid ← startRequest c headers body true
  awaitResponse c sid

end Client
end H2
