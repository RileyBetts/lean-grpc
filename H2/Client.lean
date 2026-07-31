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
import H2.Transport

open Std.Async
open Std.Net

namespace H2

structure ClientConn where
  transport : ByteTransport
  state : IO.Ref ConnState
  readBuf : IO.Ref ByteArray

structure Response where
  headers : Array Hpack.HeaderField
  trailers : Array Hpack.HeaderField
  data : ByteArray
  deriving Inhabited

namespace Client

/-- Finish HTTP/2 client preface + settings exchange on an already-connected transport. -/
def connectTransport (t : ByteTransport) : IO ClientConn := do
  t.send clientPreface
  let st := ConnState.create (isServer := false)
  sendFrames t #[Frame.settings #[
    (.initialWindowSize, st.ourSettings.initialWindowSize),
    (.maxFrameSize, st.ourSettings.maxFrameSize)
  ]]
  let state ← IO.mkRef st
  let readBuf ← IO.mkRef ByteArray.empty
  let mut buf := ByteArray.empty
  let mut gotSettings := false
  for _ in [:20] do
    match (← t.recv? 65536) with
    | none => break
    | some chunk =>
      buf := Bytes.Pool.pushBytes buf chunk
      let st0 ← state.get
      let (frames, consumed) ← IO.ofExcept
        (decodeFrames (Bytes.Slice.ofByteArray buf) st0.ourSettings.maxFrameSize.toNat)
      buf := buf.extract consumed buf.size
      let mut st := st0
      for f in frames do
        let (st', outs) ← IO.ofExcept (handleFrame st f)
        st := st'
        sendFrames t outs
        -- SETTINGS ACK is already emitted by `handleFrame`; do not send a second ACK
        -- (grpc C-core / Python rejects unexpected SETTINGS ACKs with GOAWAY).
        if f.type == .settings && !(Flags.has f.flags Flags.ack) then
          gotSettings := true
      state.set st
      if gotSettings then break
  readBuf.set buf
  return { transport := t, state, readBuf }

def connectH2c (host : String) (port : UInt16) : IO ClientConn := do
  let sock ← TCP.Socket.Client.mk
  let addr ←
    match IPv4Addr.ofString host with
    | some a => pure (SocketAddress.v4 { addr := a, port })
    | none => pure (SocketAddress.v4 { addr := IPv4Addr.ofParts 127 0 0 1, port })
  (sock.connect addr).block
  connectTransport (tcpTransport sock)

/-- Start a new request stream; returns stream id.
    When `endStream = false`, headers are sent and the stream stays open for DATA. -/
def startRequest (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray)
    (endStream : Bool := true) : IO UInt32 := do
  let mut st ← c.state.get
  let sid := st.nextClientStreamId
  st := { st with nextClientStreamId := sid + 2 }
  let s := { Stream.create sid st.peerSettings.initialWindowSize st.ourSettings.initialWindowSize
             with state := .open }
  st := st.upsertStream s
  c.state.set st
  let block := Hpack.encodeHeadersIndexed headers
  -- Peers such as grpc-go FullDuplex empty_stream expect END_STREAM on DATA,
  -- not on the initial HEADERS, when the request body is empty.
  if body.size == 0 && endStream then
    sendFrames c.transport #[
      Frame.headers sid block false true,
      Frame.data sid ByteArray.empty true
    ]
  else if body.size == 0 && !endStream then
    sendFrames c.transport #[Frame.headers sid block false true]
  else
    sendFrames c.transport #[Frame.headers sid block false true]
    sendFrames c.transport (Frame.dataFragmented sid body endStream st.ourSettings.maxFrameSize.toNat)
  return sid

/-- Wait for response headers + data + optional trailers.
    When `deadlineMs?` is set, RST_STREAM + throw after wall-clock expiry. -/
partial def awaitResponse (c : ClientConn) (streamId : UInt32) (fuel : Nat := 200)
    (deadlineMs? : Option Nat := none) (t0 : Nat := 0) : IO Response := do
  if fuel == 0 then throw (IO.userError "timeout waiting response")
  if let some ms := deadlineMs? then
    let now ← IO.monoMsNow
    if now - t0 ≥ ms then
      sendFrames c.transport #[Frame.rstStream streamId 0x8]
      throw (IO.userError "DEADLINE_EXCEEDED")
  let st ← c.state.get
  if let some s := st.getStream streamId then
    if s.endStreamRemote && s.endHeaders then
      let trailersReady := s.endTrailers || s.trailersBuf.isEmpty
      if trailersReady then
        return {
          headers := s.requestHeaders
          trailers := s.decodedTrailers
          data := s.dataBuf
        }
  match (← c.transport.recv? 65536) with
  | none => throw (IO.userError "EOF")
  | some chunk =>
    let mut buf ← c.readBuf.get
    buf := Bytes.Pool.pushBytes buf chunk
    let st0 ← c.state.get
    let (frames, consumed) ← IO.ofExcept
      (decodeFrames (Bytes.Slice.ofByteArray buf) st0.ourSettings.maxFrameSize.toNat)
    c.readBuf.set (buf.extract consumed buf.size)
    let mut st := st0
    for f in frames do
      let (st', outs) ← IO.ofExcept (handleFrame st f)
      st := st'
      sendFrames c.transport outs
    c.state.set st
    awaitResponse c streamId (fuel - 1) deadlineMs? t0

def unary (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray)
    (deadlineMs? : Option Nat := none) : IO Response := do
  let sid ← startRequest c headers body true
  let t0 ← IO.monoMsNow
  try
    awaitResponse c sid 200 deadlineMs? t0
  catch e =>
    if (toString e).contains "DEADLINE_EXCEEDED" then
      return {
        headers := #[]
        trailers := #[
          ⟨"grpc-status".toUTF8, "4".toUTF8⟩,
          ⟨"grpc-message".toUTF8, "deadline exceeded".toUTF8⟩
        ]
        data := ByteArray.empty
      }
    else throw e

/-- Send RST_STREAM to cancel a stream. -/
def resetStream (c : ClientConn) (streamId : UInt32) (errorCode : UInt32 := 0x8) : IO Unit := do
  sendFrames c.transport #[Frame.rstStream streamId errorCode]

end Client
end H2
