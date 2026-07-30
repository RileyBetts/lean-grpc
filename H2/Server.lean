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

/-- Callback when a stream has finished receiving headers (+ optional data). -/
abbrev StreamHandler :=
  (streamId : UInt32) → (headers : Array Hpack.HeaderField) → (data : ByteArray) →
    IO (Array Hpack.HeaderField × ByteArray × Bool)
  -- returns response headers, body, endStream

private def parseAddr (host : String) (port : UInt16) : IO SocketAddress := do
  match IPv4Addr.ofString host with
  | some a => return .v4 { addr := a, port }
  | none =>
    -- fallback loopback
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
    -- Invoke application only when request headers + end-of-stream are complete.
    if let some s := st.getStream f.streamId then
      if s.endHeaders && s.endStreamRemote && s.state != .closed then
        match Hpack.decodeHeaders (Bytes.Slice.ofByteArray s.headersBuf) st.decoderTable with
        | .error e => throw (IO.userError e)
        | .ok (hdrs, table) =>
          st := { st with decoderTable := table }
          let (respHdrs, body, endS) ← handler s.id hdrs s.dataBuf
          let block := Hpack.encodeHeadersIndexed respHdrs
          let hdrEnd := body.size == 0 && endS
          replies := replies.push (Frame.headers s.id block hdrEnd true)
          if body.size > 0 then
            replies := replies ++ Frame.dataFragmented s.id body endS st.ourSettings.maxFrameSize.toNat
          st := st.upsertStream { s with state := .closed, headersBuf := ByteArray.empty, dataBuf := ByteArray.empty }
  sendFrames sock replies
  let rest := buf.extract consumed buf.size
  return (st, rest)

/-- Serve one accepted TCP client as h2c prior-knowledge. -/
partial def serveConn (sock : TCP.Socket.Client) (handler : StreamHandler) : IO Unit := do
  -- Expect client preface
  let (preface, leftover) ← recvExact sock clientPreface.size
  if preface != clientPreface then
    throw (IO.userError s!"bad client preface got={Bytes.BE.hexDump (Bytes.Slice.ofByteArray preface)}")
  let mut st := ConnState.create
  -- Send server SETTINGS
  sendFrames sock #[Frame.settings #[
    (.initialWindowSize, st.ourSettings.initialWindowSize),
    (.maxConcurrentStreams, st.ourSettings.maxConcurrentStreams),
    (.maxFrameSize, st.ourSettings.maxFrameSize)
  ]]
  let mut buf := leftover
  -- Process any frames already read with the preface (e.g. client SETTINGS).
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

/-- Listen for h2c connections and serve them sequentially (simple accept loop). -/
partial def listenH2c (cfg : ServerConfig) (handler : StreamHandler) : IO Unit := do
  let server ← TCP.Socket.Server.mk
  let addr ← parseAddr cfg.host cfg.port
  server.bind addr
  server.listen 128
  IO.println s!"H2 h2c listening on {cfg.host}:{cfg.port}"
  while true do
    let client ← server.accept.block
    try
      serveConn client handler
    catch e =>
      IO.eprintln s!"conn error: {e}"

namespace Server
def listen := listenH2c
end Server

end H2
