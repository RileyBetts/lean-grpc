/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.BE
import Bytes.Pool
import H2.Settings

namespace H2

inductive FrameType where
  | data | headers | priority | rstStream | settings | pushPromise
  | ping | goAway | windowUpdate | continuation | unknown (n : UInt8)
  deriving BEq, Inhabited

def FrameType.toU8 : FrameType → UInt8
  | .data => 0 | .headers => 1 | .priority => 2 | .rstStream => 3
  | .settings => 4 | .pushPromise => 5 | .ping => 6 | .goAway => 7
  | .windowUpdate => 8 | .continuation => 9 | .unknown n => n

def FrameType.ofU8 : UInt8 → FrameType
  | 0 => .data | 1 => .headers | 2 => .priority | 3 => .rstStream
  | 4 => .settings | 5 => .pushPromise | 6 => .ping | 7 => .goAway
  | 8 => .windowUpdate | 9 => .continuation | n => .unknown n

/-- Frame flags as bitset. -/
structure Flags where
  raw : UInt8
  deriving BEq, Inhabited

namespace Flags
def none : Flags := ⟨0⟩
def endStream : Flags := ⟨0x1⟩
def endHeaders : Flags := ⟨0x4⟩
def padded : Flags := ⟨0x8⟩
def priority : Flags := ⟨0x20⟩
def ack : Flags := ⟨0x1⟩  -- SETTINGS/PING
def has (f : Flags) (bit : Flags) : Bool := (f.raw &&& bit.raw) != 0
def union (a b : Flags) : Flags := ⟨a.raw ||| b.raw⟩
end Flags

structure Frame where
  type : FrameType
  flags : Flags
  streamId : UInt32
  payload : ByteArray
  deriving Inhabited

namespace Frame

def headerSize : Nat := 9

def encode (f : Frame) : ByteArray :=
  let len : UInt32 := f.payload.size.toUInt32
  Id.run do
    let mut out := Bytes.BE.u24Bytes len
    out := out.push f.type.toU8
    out := out.push f.flags.raw
    -- stream id 31-bit BE
    let sid := f.streamId &&& 0x7fffffff
    out := Bytes.Pool.pushBytes out (Bytes.BE.u32Bytes sid)
    out := Bytes.Pool.pushBytes out f.payload
    return out

def decode (buf : Bytes.Slice) : Except String (Frame × Nat) := do
  if buf.size < 9 then throw "short frame header"
  let len ← Bytes.BE.readU24 buf 0 |>.elim (throw "len") pure
  let typ := FrameType.ofU8 (buf.get! 3)
  let flags : Flags := ⟨buf.get! 4⟩
  let sid ← Bytes.BE.readU32 buf 5 |>.elim (throw "sid") pure
  let sid := sid &&& 0x7fffffff
  let total := 9 + len.toNat
  if buf.size < total then throw "short frame payload"
  let payload := (buf.sub 9 len.toNat).toByteArray
  return (⟨typ, flags, sid, payload⟩, total)

def settingsAck : Frame :=
  ⟨.settings, Flags.ack, 0, ByteArray.empty⟩

def settings (pairs : Array (SettingId × UInt32)) : Frame :=
  Id.run do
    let mut payload := ByteArray.empty
    for (id, v) in pairs do
      payload := Bytes.Pool.pushBytes payload (Bytes.BE.u16Bytes id.toU16)
      payload := Bytes.Pool.pushBytes payload (Bytes.BE.u32Bytes v)
    return ⟨.settings, Flags.none, 0, payload⟩

def windowUpdate (streamId : UInt32) (increment : UInt32) : Frame :=
  ⟨.windowUpdate, Flags.none, streamId, Bytes.BE.u32Bytes (increment &&& 0x7fffffff)⟩

def ping (data : ByteArray) (ack : Bool := false) : Frame :=
  let flags := if ack then Flags.ack else Flags.none
  let payload :=
    if data.size == 8 then data
    else Id.run do
      let mut p := ByteArray.empty
      for i in [:8] do
        p := p.push (if i < data.size then data.get! i else 0)
      return p
  ⟨.ping, flags, 0, payload⟩

def goAway (lastStream : UInt32) (errorCode : UInt32) : Frame :=
  let payload := Bytes.Pool.pushBytes (Bytes.BE.u32Bytes (lastStream &&& 0x7fffffff)) (Bytes.BE.u32Bytes errorCode)
  ⟨.goAway, Flags.none, 0, payload⟩

def rstStream (streamId : UInt32) (errorCode : UInt32) : Frame :=
  ⟨.rstStream, Flags.none, streamId, Bytes.BE.u32Bytes errorCode⟩

def data (streamId : UInt32) (payload : ByteArray) (endStream : Bool := false) : Frame :=
  let flags := if endStream then Flags.endStream else Flags.none
  ⟨.data, flags, streamId, payload⟩

/-- Split payload into DATA frames of at most `maxSize` bytes. -/
def dataFragmented (streamId : UInt32) (payload : ByteArray) (endStream : Bool)
    (maxSize : Nat := 16384) : Array Frame :=
  Id.run do
    if payload.size == 0 then
      return if endStream then #[data streamId ByteArray.empty true] else #[]
    let mut frames : Array Frame := #[]
    let mut off : Nat := 0
    while off < payload.size do
      let take := min maxSize (payload.size - off)
      let chunk := payload.extract off (off + take)
      off := off + take
      let last := off ≥ payload.size
      frames := frames.push (data streamId chunk (last && endStream))
    return frames

def headers (streamId : UInt32) (block : ByteArray) (endStream endHeaders : Bool) : Frame :=
  let flags :=
    let f := if endHeaders then Flags.endHeaders else Flags.none
    if endStream then Flags.union f Flags.endStream else f
  ⟨.headers, flags, streamId, block⟩

/-- Strip PADDED / PRIORITY framing from a HEADERS payload, leaving the HPACK block. -/
def stripHeaderPayload (flags : Flags) (payload : ByteArray) : Except String ByteArray := do
  let mut p := payload
  if Flags.has flags Flags.padded then
    if p.size == 0 then throw "HEADERS pad length missing"
    let pad := p.get! 0 |>.toNat
    if p.size < 1 + pad then throw "HEADERS padding truncated"
    p := p.extract 1 (p.size - pad)
  if Flags.has flags Flags.priority then
    if p.size < 5 then throw "HEADERS priority truncated"
    p := p.extract 5 p.size
  return p

end Frame
end H2
