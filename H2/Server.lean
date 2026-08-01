/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std.Async.TCP
import Std.Net.Addr
import Bytes.Slice
import Bytes.Pool
import Hpack
import Bytes.BE
import H2.Preface
import H2.Frame
import H2.Connection
import H2.Transport

open Std.Async
open Std.Net

namespace H2

structure ServerConfig where
  host : String := "127.0.0.1"
  port : UInt16 := 50051
  deriving Inhabited

/-- Application result for a stream event. -/
structure StreamResponse where
  headers : Array Hpack.HeaderField := #[]
  body : ByteArray := ByteArray.empty
  trailers : Array Hpack.HeaderField := #[]
  /-- If true, stream is finished (send trailers / END_STREAM). -/
  finished : Bool := true
  deriving Inhabited

/-- Callback when a stream has request headers and (optionally incremental) data.
    `endStream` is true when the client half-closed the stream. -/
abbrev StreamHandler :=
  (streamId : UInt32) → (headers : Array Hpack.HeaderField) → (data : ByteArray) →
    (endStream : Bool) → (headersAlreadySent : Bool) → IO StreamResponse

private def parseAddr (host : String) (port : UInt16) : IO SocketAddress := do
  match IPv4Addr.ofString host with
  | some a => return .v4 { addr := a, port }
  | none =>
    return .v4 { addr := IPv4Addr.ofParts 127 0 0 1, port }

def sendFrames (t : ByteTransport) (frames : Array Frame) : IO Unit := do
  for f in frames do
    t.send (Frame.encode f)

/-- Read until we have at least `n` bytes; returns exactly `n` bytes and any leftover. -/
partial def recvExact (t : ByteTransport) (need : Nat) (acc : ByteArray := ByteArray.empty) :
    IO (ByteArray × ByteArray) := do
  if acc.size ≥ need then
    return (acc.extract 0 need, acc.extract need acc.size)
  match (← t.recv? 65536) with
  | none => throw (IO.userError "EOF")
  | some chunk => recvExact t need (Bytes.Pool.pushBytes acc chunk)

/-- Build response HEADERS frames only; DATA is queued via `queueSend` for flow control. -/
def responseHeaderFrames (streamId : UInt32) (headers : Array Hpack.HeaderField)
    (bodyEmpty : Bool) (trailersEmpty : Bool) (headersAlreadySent : Bool) (finished : Bool) :
    Array Frame :=
  Id.run do
    if headersAlreadySent || headers.isEmpty then return #[]
    let endOnHeaders := finished && bodyEmpty && trailersEmpty
    let hdrBlock := Hpack.encodeHeadersIndexed headers
    return #[Frame.headers streamId hdrBlock endOnHeaders true]

/-- Drain buffered reads into frames and handle them. -/
partial def processBuffer (t : ByteTransport) (st : ConnState) (buf : ByteArray)
    (handler : StreamHandler) : IO (ConnState × ByteArray) := do
  let (frames, consumed) ←
    match decodeFrames (Bytes.Slice.ofByteArray buf) st.ourSettings.maxFrameSize.toNat with
    | .error e =>
      if e.startsWith "frame too large" then
        sendFrames t #[Frame.goAway st.lastPeerStreamId 0x6] -- FRAME_SIZE_ERROR
        return ({ st with wentAway := true }, ByteArray.empty)
      else throw (IO.userError e)
    | .ok x => pure x
  let mut st := st
  let mut replies : Array Frame := #[]
  for f in frames do
    let (st', outs) ← IO.ofExcept (handleFrame st f)
    st := st'
    replies := replies ++ outs
    if let some s := st.getStream f.streamId then
      if s.endHeaders && s.state != .closed then
        -- After `finished := true`, only flushPending may run (no re-invoke).
        -- Incremental duplex keeps invoking until it returns finished (trailers).
        let shouldInvoke :=
          !s.handlerFinished && (s.endStreamRemote || (s.dataBuf.size > s.dataConsumed))
        if shouldInvoke then
          let hdrs := s.requestHeaders
          let fresh := s.dataBuf.extract s.dataConsumed s.dataBuf.size
          let resp ← handler s.id hdrs fresh s.endStreamRemote s.responseHeadersSent
          let emitFrames := !resp.headers.isEmpty || resp.body.size > 0 ||
            (resp.finished && (s.responseHeadersSent || !resp.headers.isEmpty || !resp.trailers.isEmpty))
          if emitFrames then
            replies := replies ++ responseHeaderFrames s.id resp.headers
              (resp.body.size == 0) resp.trailers.isEmpty s.responseHeadersSent resp.finished
            let headersNowSent := s.responseHeadersSent || !resp.headers.isEmpty
            let endOnHeaders := resp.finished && resp.body.size == 0 && resp.trailers.isEmpty
              && !s.responseHeadersSent && !resp.headers.isEmpty
            -- Keep stream open until flushPending finishes (flow-control WINDOW_UPDATE).
            let s := { s with
              dataConsumed := s.dataBuf.size
              responseHeadersSent := headersNowSent
              handlerFinished := resp.finished || s.handlerFinished
              headersBuf := if resp.finished then ByteArray.empty else s.headersBuf
              dataBuf := if resp.finished then ByteArray.empty else s.dataBuf
              trailersBuf := if resp.finished then ByteArray.empty else s.trailersBuf }
            st := st.upsertStream s
            if !endOnHeaders && (resp.body.size > 0 || !resp.trailers.isEmpty ||
                (resp.finished && headersNowSent)) then
              let (st', dataFrames) := queueSend st s.id resp.body resp.trailers resp.finished
              st := st'
              replies := replies ++ dataFrames
          else
            let advanced := resp.finished || resp.body.size > 0 || !resp.headers.isEmpty
            let s := { s with
              dataConsumed := if advanced then s.dataBuf.size else s.dataConsumed
              responseHeadersSent := s.responseHeadersSent || !resp.headers.isEmpty
              handlerFinished := resp.finished || s.handlerFinished
              state := if resp.finished then .closed else s.state
              headersBuf := if resp.finished then ByteArray.empty else s.headersBuf
              dataBuf := if resp.finished then ByteArray.empty else s.dataBuf
              trailersBuf := if resp.finished then ByteArray.empty else s.trailersBuf }
            st := st.upsertStream s
  sendFrames t replies
  let rest := buf.extract consumed buf.size
  return (st, rest)

/-- Serve one accepted client as h2c prior-knowledge (or TLS already terminated). -/
partial def serveConn (t : ByteTransport) (handler : StreamHandler) : IO Unit := do
  let (preface, leftover) ← recvExact t clientPreface.size
  if preface != clientPreface then
    throw (IO.userError s!"bad client preface got={Bytes.BE.hexDump (Bytes.Slice.ofByteArray preface)}")
  let mut st := ConnState.create
  sendFrames t #[Frame.settings #[
    (.initialWindowSize, st.ourSettings.initialWindowSize),
    (.maxConcurrentStreams, st.ourSettings.maxConcurrentStreams),
    (.maxFrameSize, st.ourSettings.maxFrameSize),
    (.maxHeaderListSize, st.ourSettings.maxHeaderListSize)
  ]]
  let mut buf := leftover
  if buf.size > 0 then
    let (st', rest) ← processBuffer t st buf handler
    st := st'
    buf := rest
  while !st.wentAway do
    match (← t.recv? 65536) with
    | none => break
    | some chunk =>
      buf := Bytes.Pool.pushBytes buf chunk
      let (st', rest) ← processBuffer t st buf handler
      st := st'
      buf := rest

/-- Listen for h2c connections; each accepted client is served concurrently. -/
partial def listenH2c (cfg : ServerConfig) (handler : StreamHandler) : IO Unit := do
  let server ← TCP.Socket.Server.mk
  let addr ← parseAddr cfg.host cfg.port
  server.bind addr
  server.listen 128
  IO.println s!"H2 h2c listening on {cfg.host}:{cfg.port}"
  while true do
    let client ← server.accept.block
    discard <| IO.asTask (prio := .dedicated) do
      try
        serveConn (tcpTransport client) handler
      catch e =>
        IO.eprintln s!"conn error: {e}"

/-- Serve using a pre-built transport (e.g. in-process TLS accept). -/
def serveTransport (t : ByteTransport) (handler : StreamHandler) : IO Unit :=
  serveConn t handler

namespace Server
def listen := listenH2c
end Server

end H2
