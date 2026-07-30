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
  deriving Inhabited

namespace ConnState

def create (cfg : ConnConfig := {}) : ConnState :=
  { ourSettings := cfg.ourSettings
    peerSettings := {}
    streams := #[]
    nextClientStreamId := 1
    lastPeerStreamId := 0
    -- Connection window starts at 65535; SETTINGS_INITIAL_WINDOW_SIZE does not change it.
    sendConnWindow := 65535
    recvConnWindow := 65535
    encoderTable := Hpack.DynamicTable.empty cfg.ourSettings.headerTableSize.toNat
    decoderTable := Hpack.DynamicTable.empty
    wentAway := false }

def findStreamIdx (st : ConnState) (id : UInt32) : Option Nat :=
  st.streams.findIdx? (·.id == id)

def upsertStream (st : ConnState) (s : Stream) : ConnState :=
  match findStreamIdx st s.id with
  | some i => { st with streams := st.streams.set! i s }
  | none => { st with streams := st.streams.push s }

def getStream (st : ConnState) (id : UInt32) : Option Stream :=
  st.streams.find? (·.id == id)

/-- Adjust every stream send window by `delta` (SETTINGS_INITIAL_WINDOW_SIZE). -/
def applySendWindowDelta (st : ConnState) (delta : Int) : Except String ConnState := do
  let mut streams := #[]
  for s in st.streams do
    let w := s.sendWindow + delta
    if w > (0x7fffffff : Int) then throw "flow control window overflow"
    streams := streams.push { s with sendWindow := w }
  return { st with streams }

end ConnState

/-- Parse SETTINGS payload into state updates (values processed in order). -/
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
private def errFrameSize : UInt32 := 0x6
private def errFlowControl : UInt32 := 0x3
private def errCompression : UInt32 := 0x9

private def connError (st : ConnState) (code : UInt32) : ConnState × Array Frame :=
  ({ st with wentAway := true }, #[Frame.goAway st.lastPeerStreamId code])

/-- Emit as much of `pendingSend` as flow control allows. -/
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

/-- Queue body/trailers on a stream and flush what the window allows. -/
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

/-- Feed one decoded frame into the connection state; returns frames to write back. -/
def handleFrame (st : ConnState) (f : Frame) : Except String (ConnState × Array Frame) := do
  match f.type with
  | .settings =>
    if f.streamId != 0 then
      return connError st errProtocol
    if Flags.has f.flags Flags.ack then
      if f.payload.size != 0 then
        return connError st errFrameSize
      return (st, #[])
    match applySettingsPayload st f.payload false with
    | .error e =>
      if e == "window too large" then return connError st errFlowControl
      else if e == "flow control window overflow" then return connError st errFlowControl
      else return connError st errProtocol
    | .ok st =>
      -- Flush any streams unblocked by a larger INITIAL_WINDOW_SIZE.
      let mut st := st
      let mut outs : Array Frame := #[Frame.settingsAck]
      for s in st.streams do
        let (st', frames) := flushPending st s.id
        st := st'
        outs := outs ++ frames
      return (st, outs)
  | .ping =>
    if f.streamId != 0 then
      return connError st errProtocol
    if f.payload.size != 8 then
      return connError st errFrameSize
    if Flags.has f.flags Flags.ack then
      return (st, #[])
    else
      return (st, #[Frame.ping f.payload (ack := true)])
  | .windowUpdate =>
    if f.payload.size != 4 then
      return connError st errFrameSize
    let inc ← Bytes.BE.readU32 (Bytes.Slice.ofByteArray f.payload) 0 |>.elim (throw "wu") pure
    let inc := (inc &&& 0x7fffffff).toNat
    if inc == 0 then
      if f.streamId == 0 then return connError st errProtocol
      else return (st, #[Frame.rstStream f.streamId errProtocol])
    if f.streamId == 0 then
      let st := { st with sendConnWindow := st.sendConnWindow + (inc : Int) }
      let mut st := st
      let mut outs : Array Frame := #[]
      for s in st.streams do
        let (st', frames) := flushPending st s.id
        st := st'
        outs := outs ++ frames
      return (st, outs)
    else
      match st.getStream f.streamId with
      | none => return (st, #[])
      | some s =>
        let s := { s with sendWindow := s.sendWindow + (inc : Int) }
        return flushPending (st.upsertStream s) f.streamId
  | .headers =>
    if f.streamId == 0 then
      return connError st errProtocol
    let block ← Frame.stripHeaderPayload f.flags f.payload
    let existing := st.getStream f.streamId
    let mut s := existing.getD
      (Stream.create f.streamId st.peerSettings.initialWindowSize st.ourSettings.initialWindowSize)
    if existing.isNone then
      let openCount := st.streams.foldl (fun n s =>
        if s.state == .closed then n else n + 1) 0
      if openCount ≥ st.ourSettings.maxConcurrentStreams.toNat then
        return (st, #[Frame.rstStream f.streamId 0x7]) -- REFUSED_STREAM
    if s.state == .idle then
      s := { s with state := .open }
    if s.gotHeaders then
      s := { s with trailersBuf := Bytes.Pool.pushBytes s.trailersBuf block }
      if Flags.has f.flags Flags.endHeaders then
        s := { s with endTrailers := true }
    else
      s := { s with headersBuf := Bytes.Pool.pushBytes s.headersBuf block }
      if Flags.has f.flags Flags.endHeaders then
        s := { s with endHeaders := true, gotHeaders := true }
    if Flags.has f.flags Flags.endStream then
      s := { s with endStreamRemote := true, state := .halfClosedRemote
                    endTrailers := s.endTrailers || s.gotHeaders }
    let st := { st with lastPeerStreamId := if f.streamId > st.lastPeerStreamId then f.streamId else st.lastPeerStreamId }
    return (st.upsertStream s, #[])
  | .continuation =>
    if f.streamId == 0 then
      return connError st errProtocol
    match st.getStream f.streamId with
    | none => return connError st errProtocol
    | some s =>
      if s.gotHeaders && !s.endTrailers then
        let s := { s with
          trailersBuf := Bytes.Pool.pushBytes s.trailersBuf f.payload
          endTrailers := Flags.has f.flags Flags.endHeaders }
        return (st.upsertStream s, #[])
      else
        let s := { s with
          headersBuf := Bytes.Pool.pushBytes s.headersBuf f.payload
          endHeaders := Flags.has f.flags Flags.endHeaders
          gotHeaders := Flags.has f.flags Flags.endHeaders || s.gotHeaders }
        return (st.upsertStream s, #[])
  | .data =>
    if f.streamId == 0 then
      return connError st errProtocol
    match st.getStream f.streamId with
    | none => return (st, #[Frame.rstStream f.streamId errProtocol])
    | some s =>
      let mut payload := f.payload
      if Flags.has f.flags Flags.padded then
        if payload.size == 0 then throw "pad"
        let pad := payload.get! 0 |>.toNat
        if payload.size < 1 + pad then throw "DATA padding truncated"
        payload := payload.extract 1 (payload.size - pad)
      let s := { s with
        dataBuf := Bytes.Pool.pushBytes s.dataBuf payload
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
    if f.streamId == 0 || f.payload.size != 4 then
      return connError st (if f.payload.size != 4 then errFrameSize else errProtocol)
    match st.getStream f.streamId with
    | none => return (st, #[])
    | some s => return (st.upsertStream { s with state := .closed }, #[])
  | .goAway =>
    if f.streamId != 0 then
      return connError st errProtocol
    return ({ st with wentAway := true }, #[])
  | .pushPromise =>
    return connError st errProtocol
  | .priority | .unknown _ =>
    return (st, #[])

/-- Begin graceful drain: stop accepting new streams conceptually and notify peer. -/
def goAwayFrames (st : ConnState) (errorCode : UInt32 := 0) : Array Frame :=
  #[Frame.goAway st.lastPeerStreamId errorCode]

/-- Unused but retained for documentation of h2spec compression errors. -/
def compressionError (_st : ConnState) : UInt32 := errCompression

/-- Decode as many complete frames as possible from a buffer. -/
def decodeFrames (buf : Bytes.Slice) : Except String (Array Frame × Nat) := do
  let mut frames : Array Frame := #[]
  let mut off : Nat := 0
  while off < buf.size do
    let remaining := buf.sub off (buf.size - off)
    if remaining.size < 9 then break
    match Frame.decode remaining with
    | .error _ => break
    | .ok (f, n) =>
      frames := frames.push f
      off := off + n
  return (frames, off)

end H2
