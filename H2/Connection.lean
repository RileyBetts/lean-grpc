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
    sendConnWindow := cfg.ourSettings.initialWindowSize.toNat
    recvConnWindow := cfg.ourSettings.initialWindowSize.toNat
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

end ConnState

/-- Parse SETTINGS payload into state updates. -/
def applySettingsPayload (st : ConnState) (payload : ByteArray) (ack : Bool) :
    Except String ConnState := do
  if ack then return st
  if payload.size % 6 != 0 then throw "SETTINGS size"
  let mut peer := st.peerSettings
  let s := Bytes.Slice.ofByteArray payload
  let mut off : Nat := 0
  while off + 6 ≤ s.size do
    let id ← Bytes.BE.readU16 s off |>.elim (throw "id") pure
    let v ← Bytes.BE.readU32 s (off + 2) |>.elim (throw "v") pure
    peer ← Settings.apply peer (SettingId.ofU16 id) v
    off := off + 6
  return { st with peerSettings := peer }

/-- Feed one decoded frame into the connection state; returns frames to write back. -/
def handleFrame (st : ConnState) (f : Frame) : Except String (ConnState × Array Frame) := do
  match f.type with
  | .settings =>
    let st ← applySettingsPayload st f.payload (Flags.has f.flags Flags.ack)
    if Flags.has f.flags Flags.ack then
      return (st, #[])
    else
      return (st, #[Frame.settingsAck])
  | .ping =>
    if Flags.has f.flags Flags.ack then
      return (st, #[])
    else
      return (st, #[Frame.ping f.payload (ack := true)])
  | .windowUpdate =>
    if f.payload.size != 4 then throw "WINDOW_UPDATE size"
    let inc ← Bytes.BE.readU32 (Bytes.Slice.ofByteArray f.payload) 0 |>.elim (throw "wu") pure
    let inc := (inc &&& 0x7fffffff).toNat
    if f.streamId == 0 then
      return ({ st with sendConnWindow := st.sendConnWindow + (inc : Int) }, #[])
    else
      match st.getStream f.streamId with
      | none => return (st, #[])
      | some s =>
        let s := { s with sendWindow := s.sendWindow + (inc : Int) }
        return (st.upsertStream s, #[])
  | .headers =>
    let block ← Frame.stripHeaderPayload f.flags f.payload
    let existing := st.getStream f.streamId
    let mut s := existing.getD (Stream.create f.streamId st.ourSettings.initialWindowSize)
    if existing.isNone then
      let openCount := st.streams.foldl (fun n s =>
        if s.state == .closed then n else n + 1) 0
      if openCount ≥ st.ourSettings.maxConcurrentStreams.toNat then
        return (st, #[Frame.rstStream f.streamId 0x7]) -- REFUSED_STREAM
    if s.state == .idle then
      s := { s with state := .open }
    -- Second header block (after first END_HEADERS) is trailers.
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
    match st.getStream f.streamId with
    | none => throw "CONTINUATION without HEADERS"
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
    match st.getStream f.streamId with
    | none => throw "DATA on unknown stream"
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
    match st.getStream f.streamId with
    | none => return (st, #[])
    | some s => return (st.upsertStream { s with state := .closed }, #[])
  | .goAway =>
    return ({ st with wentAway := true }, #[])
  | .priority | .pushPromise | .unknown _ =>
    return (st, #[])

/-- Begin graceful drain: stop accepting new streams conceptually and notify peer. -/
def goAwayFrames (st : ConnState) (errorCode : UInt32 := 0) : Array Frame :=
  #[Frame.goAway st.lastPeerStreamId errorCode]


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
