/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std.Async.TCP
import Bytes.Slice
import Bytes.BE
import Bytes.Pool
import Hpack
import H2.Frame
import H2.Settings
import H2.Stream
import H2.Headers

open Std.Async

namespace H2

structure ConnConfig where
  ourSettings : Settings := {}
  deriving Inhabited

/- In-memory HTTP/2 connection state (pure protocol machine). -/
structure ConnState where
  ourSettings : Settings
  peerSettings : Settings
  streams : Array Stream
  nextClientStreamId : UInt32
  lastPeerStreamId : UInt32
  sendConnWindow : Int
  recvConnWindow : Int
  encoderTable : Hpack.DynamicTable
  decoderTable : Hpack.DynamicTable
  wentAway : Bool
  /-- When set, only CONTINUATION for this stream id is legal. -/
  expectContinuation : Option UInt32
  /-- Server connections validate request headers (§8.1). -/
  isServer : Bool
  /-- Outstanding PING payload awaiting ACK (empty = none). -/
  pendingPing : ByteArray := ByteArray.empty
  /-- Wall-ms when pendingPing was sent (0 = none). -/
  pendingPingAtMs : Nat := 0
  deriving Inhabited

namespace ConnState

def create (cfg : ConnConfig := {}) (isServer : Bool := true) : ConnState :=
  { ourSettings := cfg.ourSettings
    peerSettings := {}
    streams := #[]
    nextClientStreamId := 1
    lastPeerStreamId := 0
    sendConnWindow := 65535
    recvConnWindow := 65535
    encoderTable := Hpack.DynamicTable.empty cfg.ourSettings.headerTableSize.toNat
    decoderTable := Hpack.DynamicTable.empty
    wentAway := false
    expectContinuation := none
    isServer
    pendingPing := ByteArray.empty
    pendingPingAtMs := 0 }

def findStreamIdx (st : ConnState) (id : UInt32) : Option Nat :=
  st.streams.findIdx? (·.id == id)

def upsertStream (st : ConnState) (s : Stream) : ConnState :=
  match findStreamIdx st s.id with
  | some i => { st with streams := st.streams.set! i s }
  | none => { st with streams := st.streams.push s }

def getStream (st : ConnState) (id : UInt32) : Option Stream :=
  st.streams.find? (·.id == id)

def applySendWindowDelta (st : ConnState) (delta : Int) : Except String ConnState := do
  let mut streams := #[]
  for s in st.streams do
    let w := s.sendWindow + delta
    if w > (0x7fffffff : Int) then throw "flow control window overflow"
    streams := streams.push { s with sendWindow := w }
  return { st with streams }

end ConnState

def applySettingsPayload (st : ConnState) (payload : ByteArray) (ack : Bool) :
    Except String ConnState := do
  if ack then return st
  if payload.size % 6 != 0 then throw "SETTINGS size"
  let mut st := st
  let s := Bytes.Slice.ofByteArray payload
  let mut off : Nat := 0
  while off + 6 ≤ s.size do
    let id ← Bytes.BE.readU16 s off |>.elim (throw "id") pure
    let v ← Bytes.BE.readU32 s (off + 2) |>.elim (throw "v") pure
    let sid := SettingId.ofU16 id
    let oldWin := st.peerSettings.initialWindowSize
    let peer ← Settings.apply st.peerSettings sid v
    st := { st with peerSettings := peer }
    if sid == .initialWindowSize then
      let delta : Int := (peer.initialWindowSize.toNat : Int) - (oldWin.toNat : Int)
      if delta != 0 then
        st ← ConnState.applySendWindowDelta st delta
    off := off + 6
  return st

private def errProtocol : UInt32 := 0x1
private def errInternal : UInt32 := 0x2
private def errFlowControl : UInt32 := 0x3
private def errStreamClosed : UInt32 := 0x5
private def errFrameSize : UInt32 := 0x6
private def errRefused : UInt32 := 0x7
private def errCompression : UInt32 := 0x9

private def connError (st : ConnState) (code : UInt32) : ConnState × Array Frame :=
  ({ st with wentAway := true, expectContinuation := none },
   #[Frame.goAway st.lastPeerStreamId code])

private def streamError (st : ConnState) (sid code : UInt32) : ConnState × Array Frame :=
  match st.getStream sid with
  | none => (st, #[Frame.rstStream sid code])
  | some s =>
    (st.upsertStream { s with state := .closed }, #[Frame.rstStream sid code])

/-- Extract stream dependency from PRIORITY or prioritized HEADERS payload. -/
private def priorityDep (flags : Flags) (payload : ByteArray) (isHeaders : Bool) :
    Except String (Option UInt32) := do
  let mut p := payload
  if isHeaders && Flags.has flags Flags.padded then
    if p.size == 0 then throw "pad"
    let pad := p.get! 0 |>.toNat
    if p.size < 1 + pad then throw "pad trunc"
    p := p.extract 1 (p.size - pad)
  if isHeaders && !Flags.has flags Flags.priority then return none
  if !isHeaders && p.size != 5 then throw "priority size"
  if p.size < 5 then throw "priority trunc"
  let dep ← Bytes.BE.readU32 (Bytes.Slice.ofByteArray p) 0 |>.elim (throw "dep") pure
  return some (dep &&& 0x7fffffff)

def flushPending (st : ConnState) (streamId : UInt32) : ConnState × Array Frame :=
  Id.run do
    match st.getStream streamId with
    | none => return (st, #[])
    | some s0 =>
      let mut s := s0
      let mut st := st
      let mut frames : Array Frame := #[]
      let maxFrame := st.peerSettings.maxFrameSize.toNat
      while s.pendingSend.size > 0 do
        let allow := min s.sendWindow st.sendConnWindow
        if allow ≤ 0 then break
        let take := min (min allow.toNat maxFrame) s.pendingSend.size
        if take == 0 then break
        let chunk := s.pendingSend.extract 0 take
        let rest := s.pendingSend.extract take s.pendingSend.size
        let endNow := rest.isEmpty && s.pendingTrailers.isEmpty && s.pendingEndStream
        frames := frames.push (Frame.data streamId chunk endNow)
        s := { s with
          pendingSend := rest
          sendWindow := s.sendWindow - (take : Int)
          endStreamLocal := endNow || s.endStreamLocal
          state := if endNow then .closed else s.state }
        st := { st with sendConnWindow := st.sendConnWindow - (take : Int) }
      if s.pendingSend.isEmpty && !s.pendingTrailers.isEmpty then
        let trBlock := Hpack.encodeHeadersIndexed s.pendingTrailers
        frames := frames.push (Frame.headers streamId trBlock true true)
        s := { s with
          pendingTrailers := #[]
          pendingEndStream := false
          endStreamLocal := true
          state := .closed }
      else if s.pendingSend.isEmpty && s.pendingTrailers.isEmpty && s.pendingEndStream && !s.endStreamLocal then
        frames := frames.push (Frame.data streamId ByteArray.empty true)
        s := { s with pendingEndStream := false, endStreamLocal := true, state := .closed }
      return (st.upsertStream s, frames)

def queueSend (st : ConnState) (streamId : UInt32) (body : ByteArray)
    (trailers : Array Hpack.HeaderField) (endStream : Bool) : ConnState × Array Frame :=
  match st.getStream streamId with
  | none => (st, #[])
  | some s =>
    let s := { s with
      pendingSend := Bytes.Pool.pushBytes s.pendingSend body
      pendingTrailers := if trailers.isEmpty then s.pendingTrailers else trailers
      pendingEndStream := endStream || s.pendingEndStream }
    flushPending (st.upsertStream s) streamId

private def requireNoContinuation (st : ConnState) : Except String Unit := do
  if st.expectContinuation.isSome then throw "expected CONTINUATION"

private def finishHeaders (st : ConnState) (s : Stream) (isTrailer : Bool) :
    Except String (ConnState × Array Frame) := do
  let block := if isTrailer then s.trailersBuf else s.headersBuf
  match Hpack.decodeHeaders (Bytes.Slice.ofByteArray block) st.decoderTable
      st.ourSettings.headerTableSize.toNat with
  | .error _ => return connError st errCompression
  | .ok (hdrs, table) =>
    let st := { st with decoderTable := table }
    if st.isServer then
      match validateRequestHeaders hdrs isTrailer with
      | some _ => return connError st errProtocol
      | none => pure ()
    let s :=
      if isTrailer then { s with endTrailers := true, decodedTrailers := hdrs }
      else { s with
        endHeaders := true
        gotHeaders := true
        contentLength := expectedContentLength hdrs
        requestHeaders := hdrs }
    return (st.upsertStream s, #[])

/-- Feed one decoded frame into the connection state; returns frames to write back. -/
def handleFrame (st : ConnState) (f : Frame) : Except String (ConnState × Array Frame) := do
  -- CONTINUATION must immediately follow incomplete header blocks.
  if f.type != .continuation then
    if st.expectContinuation.isSome then
      return connError st errProtocol

  -- Frame size vs our advertised max (HEADERS/DATA/etc payload).
  if f.type != .settings && f.type != .ping && f.type != .windowUpdate &&
      f.type != .rstStream && f.type != .priority && f.type != .goAway then
    if f.payload.size > st.ourSettings.maxFrameSize.toNat then
      return connError st errFrameSize

  match f.type with
  | .settings =>
    if f.streamId != 0 then return connError st errProtocol
    if Flags.has f.flags Flags.ack then
      if f.payload.size != 0 then return connError st errFrameSize
      return (st, #[])
    match applySettingsPayload st f.payload false with
    | .error e =>
      if e == "window too large" || e == "flow control window overflow" then
        return connError st errFlowControl
      else return connError st errProtocol
    | .ok st =>
      let mut st := st
      let mut outs : Array Frame := #[Frame.settingsAck]
      for s in st.streams do
        let (st', frames) := flushPending st s.id
        st := st'
        outs := outs ++ frames
      return (st, outs)

  | .ping =>
    if f.streamId != 0 then return connError st errProtocol
    if f.payload.size != 8 then return connError st errFrameSize
    if Flags.has f.flags Flags.ack then
      -- Clear outstanding keepalive PING when ACK payload matches (or any ACK).
      return ({ st with pendingPing := ByteArray.empty, pendingPingAtMs := 0 }, #[])
    else return (st, #[Frame.ping f.payload (ack := true)])

  | .windowUpdate =>
    if f.payload.size != 4 then return connError st errFrameSize
    let raw ← Bytes.BE.readU32 (Bytes.Slice.ofByteArray f.payload) 0 |>.elim (throw "wu") pure
    let inc := (raw &&& 0x7fffffff).toNat
    if inc == 0 then
      if f.streamId == 0 then return connError st errProtocol
      else return streamError st f.streamId errProtocol
    if f.streamId == 0 then
      let newWin := st.sendConnWindow + (inc : Int)
      if newWin > (0x7fffffff : Int) then return connError st errFlowControl
      let st := { st with sendConnWindow := newWin }
      let mut st := st
      let mut outs : Array Frame := #[]
      for s in st.streams do
        let (st', frames) := flushPending st s.id
        st := st'
        outs := outs ++ frames
      return (st, outs)
    else
      match st.getStream f.streamId with
      | none =>
        -- idle stream WINDOW_UPDATE is a connection error
        return connError st errProtocol
      | some s =>
        if s.state == .idle then return connError st errProtocol
        if s.state == .closed then return (st, #[])
        let newWin := s.sendWindow + (inc : Int)
        if newWin > (0x7fffffff : Int) then
          return streamError st f.streamId errFlowControl
        let s := { s with sendWindow := newWin }
        return flushPending (st.upsertStream s) f.streamId

  | .priority =>
    if f.streamId == 0 then return connError st errProtocol
    if f.payload.size != 5 then return connError st errFrameSize
    match ← priorityDep Flags.none f.payload false with
    | some dep =>
      if dep == f.streamId then return connError st errProtocol
    | none => pure ()
    -- PRIORITY on idle is OK (creates priority info only); we ignore.
    return (st, #[])

  | .headers =>
    if f.streamId == 0 then return connError st errProtocol
    -- Peer-initiated streams: clients use odd ids toward a server.
    if st.isServer && f.streamId % 2 == 0 then return connError st errProtocol
    match ← priorityDep f.flags f.payload true with
    | some dep =>
      if dep == f.streamId then return connError st errProtocol
    | none => pure ()
    let block ← Frame.stripHeaderPayload f.flags f.payload
    let existing := st.getStream f.streamId
    -- Closed / half-closed-remote: stream error STREAM_CLOSED
    match existing with
    | some s =>
      -- HEADERS on closed is a connection error; half-closed remote is a stream error.
      if s.state == .closed then
        return connError st errStreamClosed
      if s.state == .halfClosedRemote then
        return streamError st f.streamId errStreamClosed
      -- Second HEADERS (trailers) must include END_STREAM
      if s.gotHeaders && s.endHeaders then
        if !Flags.has f.flags Flags.endStream then
          return connError st errProtocol
    | none =>
      if st.isServer && f.streamId ≤ st.lastPeerStreamId then
        return connError st errProtocol
    let mut s := existing.getD
      (Stream.create f.streamId st.peerSettings.initialWindowSize st.ourSettings.initialWindowSize)
    if existing.isNone then
      let openCount := st.streams.foldl (fun n s =>
        if s.state == .closed then n else n + 1) 0
      if openCount ≥ st.ourSettings.maxConcurrentStreams.toNat then
        return streamError st f.streamId errRefused
    if s.state == .idle then
      s := { s with state := .open }
    let isTrailer := s.gotHeaders && s.endHeaders
    if isTrailer then
      s := { s with trailersBuf := Bytes.Pool.pushBytes s.trailersBuf block }
    else
      s := { s with headersBuf := Bytes.Pool.pushBytes s.headersBuf block }
    if Flags.has f.flags Flags.endStream then
      s := { s with endStreamRemote := true, state := .halfClosedRemote }
    let st1 := { st with
      lastPeerStreamId := if f.streamId > st.lastPeerStreamId then f.streamId else st.lastPeerStreamId }
    if Flags.has f.flags Flags.endHeaders then
      let st1 := { st1 with expectContinuation := none }
      finishHeaders st1 s isTrailer
    else
      let st1 := { st1 with expectContinuation := some f.streamId }
      return (st1.upsertStream s, #[])

  | .continuation =>
    match st.expectContinuation with
    | none => return connError st errProtocol
    | some sid =>
      if f.streamId != sid then return connError st errProtocol
      match st.getStream sid with
      | none => return connError st errProtocol
      | some s =>
        if s.state == .closed || s.state == .halfClosedRemote then
          -- CONTINUATION after close / half-closed remote
          if s.state == .halfClosedRemote && !s.endHeaders then
            -- still assembling? half-closed after END_STREAM on headers before END_HEADERS is odd
            pure ()
          else if s.endHeaders || s.state == .closed then
            return streamError st sid errStreamClosed
        let isTrailer := s.gotHeaders && s.endHeaders
        -- If we already finished headers, CONTINUATION after END_HEADERS is protocol error
        -- (handled by expectContinuation=none). Here we append.
        let s :=
          if isTrailer then
            { s with trailersBuf := Bytes.Pool.pushBytes s.trailersBuf f.payload }
          else if s.gotHeaders && s.endStreamRemote && !s.endHeaders then
            { s with headersBuf := Bytes.Pool.pushBytes s.headersBuf f.payload }
          else
            { s with headersBuf := Bytes.Pool.pushBytes s.headersBuf f.payload }
        if Flags.has f.flags Flags.endHeaders then
          let st := { st with expectContinuation := none }
          finishHeaders st s (s.gotHeaders && s.endHeaders && isTrailer)
        else
          return ({ st with expectContinuation := some sid }.upsertStream s, #[])

  | .data =>
    if f.streamId == 0 then return connError st errProtocol
    match st.getStream f.streamId with
    | none => return connError st errProtocol  -- idle
    | some s =>
      if s.state == .idle then return connError st errProtocol
      if s.state == .closed || s.state == .halfClosedRemote then
        return streamError st f.streamId errStreamClosed
      if s.state != .open && s.state != .halfClosedLocal then
        return streamError st f.streamId errStreamClosed
      let mut payload := f.payload
      if Flags.has f.flags Flags.padded then
        if payload.size == 0 then return connError st errProtocol
        let pad := payload.get! 0 |>.toNat
        if payload.size < 1 + pad then return connError st errProtocol
        payload := payload.extract 1 (payload.size - pad)
      let dataBuf := Bytes.Pool.pushBytes s.dataBuf payload
      if Flags.has f.flags Flags.endStream then
        if let some expect := s.contentLength then
          if expect != dataBuf.size then
            return connError st errProtocol
      let s := { s with
        dataBuf
        recvWindow := s.recvWindow - (payload.size : Int)
        endStreamRemote := Flags.has f.flags Flags.endStream ∨ s.endStreamRemote
        state := if Flags.has f.flags Flags.endStream then .halfClosedRemote else s.state }
      let st := { st with
        recvConnWindow := st.recvConnWindow - (payload.size : Int)
        streams := (st.upsertStream s).streams }
      let mut out : Array Frame := #[]
      if st.recvConnWindow < 32768 then
        out := out.push (Frame.windowUpdate 0 65535)
      if s.recvWindow < 32768 then
        out := out.push (Frame.windowUpdate f.streamId 65535)
      return (st, out)

  | .rstStream =>
    if f.streamId == 0 then return connError st errProtocol
    if f.payload.size != 4 then return connError st errFrameSize
    match st.getStream f.streamId with
    | none => return connError st errProtocol  -- idle
    | some s =>
      if s.state == .idle then return connError st errProtocol
      let code := (Bytes.BE.readU32 (Bytes.Slice.ofByteArray f.payload) 0).getD 0
      return (st.upsertStream { s with state := .closed, rstErrorCode := some code }, #[])

  | .goAway =>
    if f.streamId != 0 then return connError st errProtocol
    return ({ st with wentAway := true }, #[])

  | .pushPromise =>
    return connError st errProtocol

  | .unknown _ =>
    -- Unknown frames ignored unless in middle of header block (already checked).
    return (st, #[])

def goAwayFrames (st : ConnState) (errorCode : UInt32 := 0) : Array Frame :=
  #[Frame.goAway st.lastPeerStreamId errorCode]

def compressionError (_st : ConnState) : UInt32 := errCompression

/-- Decode frames; reject payloads larger than `maxFrameSize` with a sentinel error. -/
def decodeFrames (buf : Bytes.Slice) (maxFrameSize : Nat := 16384) :
    Except String (Array Frame × Nat) := do
  let mut frames : Array Frame := #[]
  let mut off : Nat := 0
  while off < buf.size do
    let remaining := buf.sub off (buf.size - off)
    if remaining.size < 9 then break
    match Bytes.BE.readU24 remaining 0 with
    | none => break
    | some len =>
      if len.toNat > maxFrameSize then
        throw s!"frame too large:{len.toNat}"
      match Frame.decode remaining with
      | .error _ => break
      | .ok (f, n) =>
        frames := frames.push f
        off := off + n
  return (frames, off)

end H2
