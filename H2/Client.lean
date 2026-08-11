/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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

/-- Client connection. `transport` is async underneath; sync APIs `.block` at the edge. -/
structure ClientConn where
  transport : AsyncByteTransport
  state : IO.Ref ConnState
  readBuf : IO.Ref ByteArray

structure Response where
  headers : Array Hpack.HeaderField
  trailers : Array Hpack.HeaderField
  data : ByteArray
  /-- Peer RST_STREAM error code, if the stream was reset before a normal end. -/
  rstErrorCode : Option UInt32 := none
  deriving Inhabited

namespace Client

/-- Map HTTP/2 RST_STREAM error codes to synthesized gRPC trailers (PROTOCOL-HTTP2). -/
def rstToTrailers (code : UInt32) : Array Hpack.HeaderField :=
  let (grpc, msg) : String × String :=
    match code.toNat with
    | 0 => ("13", "NO_ERROR")           -- INTERNAL
    | 1 => ("13", "PROTOCOL_ERROR")
    | 2 => ("13", "INTERNAL_ERROR")
    | 3 => ("13", "FLOW_CONTROL_ERROR")
    | 4 => ("13", "SETTINGS_TIMEOUT")
    | 6 => ("13", "FRAME_SIZE_ERROR")
    | 7 => ("14", "REFUSED_STREAM")     -- UNAVAILABLE
    | 8 => ("1", "CANCEL")              -- CANCELLED
    | 9 => ("13", "COMPRESSION_ERROR")
    | 10 => ("13", "CONNECT_ERROR")
    | 11 => ("8", "ENHANCE_YOUR_CALM")  -- RESOURCE_EXHAUSTED
    | 12 => ("7", "INADEQUATE_SECURITY") -- PERMISSION_DENIED
    | _ => ("13", s!"RST_STREAM {code}")
  #[
    ⟨"grpc-status".toUTF8, grpc.toUTF8⟩,
    ⟨"grpc-message".toUTF8, msg.toUTF8⟩
  ]

/-- Finish HTTP/2 client preface + settings on an async transport (no `.block`). -/
def connectTransportAsync (t : AsyncByteTransport) : Async ClientConn := do
  t.send clientPreface
  let st := ConnState.create (isServer := false)
  sendFramesAsync t #[Frame.settings #[
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
      let (frames, consumed) ← liftM (IO.ofExcept
        (decodeFrames (Bytes.Slice.ofByteArray buf) st0.ourSettings.maxFrameSize.toNat))
      buf := buf.extract consumed buf.size
      let mut st := st0
      for f in frames do
        let (st', outs) ← liftM (IO.ofExcept (handleFrame st f))
        st := st'
        sendFramesAsync t outs
        if f.type == .settings && !(Flags.has f.flags Flags.ack) then
          gotSettings := true
      state.set st
      if gotSettings then break
  readBuf.set buf
  return { transport := t, state, readBuf }

/-- Sync/TLS entry: wrap blocking `ByteTransport` then run async preface via `.block`.
    Prefer calling this from an off-loop dedicated task (`H2.runOffLoop`) so OpenSSL
    does not stall the UV thread. -/
def connectTransport (t : ByteTransport) : IO ClientConn :=
  (connectTransportAsync (.ofBlocking t)).block

/-- Dial/preface on a dedicated thread (blocking OpenSSL), then return a `ClientConn`
    whose later Async send/recv use `ofBlockingOffLoop` (issue #10). -/
def connectTransportOffLoopAsync (t : ByteTransport) : Async ClientConn := do
  let c ← runOffLoop (connectTransport t)
  pure { c with transport := .ofBlockingOffLoop t }

/-- Dial h2c without `.block` on connect/send/recv. -/
def connectH2cAsync (host : String) (port : UInt16) : Async ClientConn := do
  let sock ← TCP.Socket.Client.mk
  let addr ←
    match IPv4Addr.ofString host with
    | some a => pure (SocketAddress.v4 { addr := a, port })
    | none => pure (SocketAddress.v4 { addr := IPv4Addr.ofParts 127 0 0 1, port })
  sock.connect addr
  connectTransportAsync (tcpTransportAsync sock)

/-- Sync adapter over `connectH2cAsync`. -/
def connectH2c (host : String) (port : UInt16) : IO ClientConn :=
  (connectH2cAsync host port).block

/-- Start a new request stream (Async). -/
def startRequestAsync (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray)
    (endStream : Bool := true) : Async UInt32 := do
  let mut st ← c.state.get
  let sid := st.nextClientStreamId
  st := { st with nextClientStreamId := sid + 2 }
  let s := { Stream.create sid st.peerSettings.initialWindowSize st.ourSettings.initialWindowSize
             with state := .open }
  st := st.upsertStream s
  c.state.set st
  let block := Hpack.encodeHeadersIndexed headers
  if body.size == 0 && endStream then
    sendFramesAsync c.transport #[
      Frame.headers sid block false true,
      Frame.data sid ByteArray.empty true
    ]
  else if body.size == 0 && !endStream then
    sendFramesAsync c.transport #[Frame.headers sid block false true]
  else
    sendFramesAsync c.transport #[Frame.headers sid block false true]
    sendFramesAsync c.transport (Frame.dataFragmented sid body endStream st.ourSettings.maxFrameSize.toNat)
  return sid

def startRequest (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray)
    (endStream : Bool := true) : IO UInt32 :=
  (startRequestAsync c headers body endStream).block

/-- Wait for response headers + data + optional trailers (Async — no `.block`). -/
partial def awaitResponseAsync (c : ClientConn) (streamId : UInt32) (fuel : Nat := 200)
    (deadlineMs? : Option Nat := none) (t0 : Nat := 0) : Async Response := do
  if fuel == 0 then throw (IO.userError "timeout waiting response")
  if let some ms := deadlineMs? then
    let now ← IO.monoMsNow
    if now - t0 ≥ ms then
      sendFramesAsync c.transport #[Frame.rstStream streamId 0x8]
      throw (IO.userError "DEADLINE_EXCEEDED")
  let st ← c.state.get
  if let some s := st.getStream streamId then
    if let some code := s.rstErrorCode then
      return {
        headers := s.requestHeaders
        trailers := rstToTrailers code
        data := s.dataBuf
        rstErrorCode := some code
      }
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
    let (frames, consumed) ← liftM (IO.ofExcept
      (decodeFrames (Bytes.Slice.ofByteArray buf) st0.ourSettings.maxFrameSize.toNat))
    c.readBuf.set (buf.extract consumed buf.size)
    let mut st := st0
    for f in frames do
      let (st', outs) ← liftM (IO.ofExcept (handleFrame st f))
      st := st'
      sendFramesAsync c.transport outs
    c.state.set st
    if let some s := st.getStream streamId then
      if let some code := s.rstErrorCode then
        return {
          headers := s.requestHeaders
          trailers := rstToTrailers code
          data := s.dataBuf
          rstErrorCode := some code
        }
    awaitResponseAsync c streamId (fuel - 1) deadlineMs? t0

def awaitResponse (c : ClientConn) (streamId : UInt32) (fuel : Nat := 200)
    (deadlineMs? : Option Nat := none) (t0 : Nat := 0) : IO Response :=
  (awaitResponseAsync c streamId fuel deadlineMs? t0).block

def awaitUnaryAsync (c : ClientConn) (streamId : UInt32) (deadlineMs? : Option Nat := none) :
    Async Response := do
  let t0 ← IO.monoMsNow
  try
    awaitResponseAsync c streamId 200 deadlineMs? t0
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

def awaitUnary (c : ClientConn) (streamId : UInt32) (deadlineMs? : Option Nat := none) :
    IO Response :=
  (awaitUnaryAsync c streamId deadlineMs?).block

def unaryAsync (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray)
    (deadlineMs? : Option Nat := none) : Async Response := do
  let sid ← startRequestAsync c headers body true
  awaitUnaryAsync c sid deadlineMs?

def unary (c : ClientConn) (headers : Array Hpack.HeaderField) (body : ByteArray)
    (deadlineMs? : Option Nat := none) : IO Response :=
  (unaryAsync c headers body deadlineMs?).block

def resetStreamAsync (c : ClientConn) (streamId : UInt32) (errorCode : UInt32 := 0x8) : Async Unit := do
  sendFramesAsync c.transport #[Frame.rstStream streamId errorCode]
  let st ← c.state.get
  match st.getStream streamId with
  | some s => c.state.set (st.upsertStream { s with state := .closed, rstErrorCode := some errorCode })
  | none => pure ()

def resetStream (c : ClientConn) (streamId : UInt32) (errorCode : UInt32 := 0x8) : IO Unit :=
  (resetStreamAsync c streamId errorCode).block

end Client
end H2
