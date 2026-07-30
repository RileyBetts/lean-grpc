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

def sendFrames (sock : TCP.Socket.Client) (frames : Array Frame) : IO Unit := do
  for f in frames do
    (sock.send (Frame.encode f)).block

/-- Read until we have at least `n` bytes; returns exactly `n` bytes and any leftover. -/
partial def recvExact (sock : TCP.Socket.Client) (need : Nat) (acc : ByteArray := ByteArray.empty) :
    IO (ByteArray × ByteArray) := do
  if acc.size ≥ need then
    return (acc.extract 0 need, acc.extract need acc.size)
  match (← (sock.recv? 65536).block) with
  | none => throw (IO.userError "EOF")
  | some chunk => recvExact sock need (Bytes.Pool.pushBytes acc chunk)

/-- Build response frames. If `headersAlreadySent`, only DATA (+ optional trailers). -/
def responseFrames (streamId : UInt32) (headers : Array Hpack.HeaderField)
    (body : ByteArray) (trailers : Array Hpack.HeaderField) (maxFrame : Nat)
    (headersAlreadySent : Bool) (finished : Bool) : Array Frame :=
  Id.run do
    let mut frames : Array Frame := #[]
    if !headersAlreadySent then
      if finished && trailers.isEmpty then
        let endOnHeaders := body.size == 0
        let hdrBlock := Hpack.encodeHeadersIndexed headers
        frames := frames.push (Frame.headers streamId hdrBlock endOnHeaders true)
        if body.size > 0 then
          frames := frames ++ Frame.dataFragmented streamId body true maxFrame
        return frames
      else
        let hdrBlock := Hpack.encodeHeadersIndexed headers
        frames := frames.push (Frame.headers streamId hdrBlock false true)
    if body.size > 0 then
      frames := frames ++ Frame.dataFragmented streamId body (finished && trailers.isEmpty) maxFrame
    if finished then
      if !trailers.isEmpty then
        let trBlock := Hpack.encodeHeadersIndexed trailers
        frames := frames.push (Frame.headers streamId trBlock true true)
      else if body.size == 0 && headersAlreadySent then
        frames := frames.push (Frame.data streamId ByteArray.empty true)
    return frames

/-- Drain buffered reads into frames and handle them. -/
partial def processBuffer (sock : TCP.Socket.Client) (st : ConnState) (buf : ByteArray)
    (handler : StreamHandler) : IO (ConnState × ByteArray) := do
  let (frames, consumed) ← IO.ofExcept (decodeFrames (Bytes.Slice.ofByteArray buf))
  let mut st := st
  let mut replies : Array Frame := #[]
  for f in frames do
    let (st', outs) ← IO.ofExcept (handleFrame st f)
    st := st'
    replies := replies ++ outs
    if let some s := st.getStream f.streamId then
      if s.endHeaders && s.state != .closed then
        let shouldInvoke :=
          s.endStreamRemote || (s.dataBuf.size > s.dataConsumed)
        if shouldInvoke then
          match Hpack.decodeHeaders (Bytes.Slice.ofByteArray s.headersBuf) st.decoderTable with
          | .error e => throw (IO.userError e)
          | .ok (hdrs, table) =>
            st := { st with decoderTable := table }
            let fresh := s.dataBuf.extract s.dataConsumed s.dataBuf.size
            let resp ← handler s.id hdrs fresh s.endStreamRemote s.responseHeadersSent
            let emitFrames := !resp.headers.isEmpty || resp.body.size > 0 ||
              (resp.finished && (s.responseHeadersSent || !resp.headers.isEmpty || !resp.trailers.isEmpty))
            if emitFrames then
              replies := replies ++ responseFrames s.id resp.headers resp.body resp.trailers
                st.ourSettings.maxFrameSize.toNat s.responseHeadersSent resp.finished
            let headersNowSent := s.responseHeadersSent || !resp.headers.isEmpty
            -- Only advance the data cursor when the handler consumed bytes or finished.
            let advanced := resp.finished || resp.body.size > 0 || !resp.headers.isEmpty
            let s := { s with
              dataConsumed := if advanced then s.dataBuf.size else s.dataConsumed
              responseHeadersSent := headersNowSent
              state := if resp.finished then .closed else s.state
              headersBuf := if resp.finished then ByteArray.empty else s.headersBuf
              dataBuf := if resp.finished then ByteArray.empty else s.dataBuf
              trailersBuf := if resp.finished then ByteArray.empty else s.trailersBuf }
            st := st.upsertStream s
  sendFrames sock replies
  let rest := buf.extract consumed buf.size
  return (st, rest)

/-- Serve one accepted TCP client as h2c prior-knowledge. -/
partial def serveConn (sock : TCP.Socket.Client) (handler : StreamHandler) : IO Unit := do
  let (preface, leftover) ← recvExact sock clientPreface.size
  if preface != clientPreface then
    throw (IO.userError s!"bad client preface got={Bytes.BE.hexDump (Bytes.Slice.ofByteArray preface)}")
  let mut st := ConnState.create
  sendFrames sock #[Frame.settings #[
    (.initialWindowSize, st.ourSettings.initialWindowSize),
    (.maxConcurrentStreams, st.ourSettings.maxConcurrentStreams),
    (.maxFrameSize, st.ourSettings.maxFrameSize)
  ]]
  let mut buf := leftover
  if buf.size > 0 then
    let (st', rest) ← processBuffer sock st buf handler
    st := st'
    buf := rest
  while !st.wentAway do
    match (← (sock.recv? 65536).block) with
    | none => break
    | some chunk =>
      buf := Bytes.Pool.pushBytes buf chunk
      let (st', rest) ← processBuffer sock st buf handler
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
        serveConn client handler
      catch e =>
        IO.eprintln s!"conn error: {e}"

namespace Server
def listen := listenH2c
end Server

end H2
