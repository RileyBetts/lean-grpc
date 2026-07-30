/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice

namespace Bytes
namespace BE

/-- Write big-endian u16 into a new 2-byte array. -/
def u16Bytes (n : UInt16) : ByteArray :=
  ByteArray.mk #[(n >>> 8).toUInt8, n.toUInt8]

/-- Write big-endian u32 into a new 4-byte array. -/
def u32Bytes (n : UInt32) : ByteArray :=
  ByteArray.mk #[
    (n >>> 24).toUInt8,
    (n >>> 16).toUInt8,
    (n >>> 8).toUInt8,
    n.toUInt8
  ]

/-- Write big-endian u24 (HTTP/2 frame length) into 3 bytes. -/
def u24Bytes (n : UInt32) : ByteArray :=
  ByteArray.mk #[
    (n >>> 16).toUInt8,
    (n >>> 8).toUInt8,
    n.toUInt8
  ]

def readU16 (s : Slice) (off : Nat := 0) : Option UInt16 := do
  let b0 ← s.get? off
  let b1 ← s.get? (off + 1)
  return (b0.toUInt16 <<< 8) ||| b1.toUInt16

def readU24 (s : Slice) (off : Nat := 0) : Option UInt32 := do
  let b0 ← s.get? off
  let b1 ← s.get? (off + 1)
  let b2 ← s.get? (off + 2)
  return (b0.toUInt32 <<< 16) ||| (b1.toUInt32 <<< 8) ||| b2.toUInt32

def readU32 (s : Slice) (off : Nat := 0) : Option UInt32 := do
  let b0 ← s.get? off
  let b1 ← s.get? (off + 1)
  let b2 ← s.get? (off + 2)
  let b3 ← s.get? (off + 3)
  return (b0.toUInt32 <<< 24) ||| (b1.toUInt32 <<< 16) ||| (b2.toUInt32 <<< 8) ||| b3.toUInt32

/-- Little-endian u32 (gzip CRC / ISIZE). -/
def u32BytesLE (n : UInt32) : ByteArray :=
  ByteArray.mk #[
    n.toUInt8,
    (n >>> 8).toUInt8,
    (n >>> 16).toUInt8,
    (n >>> 24).toUInt8
  ]

def readU32LE (s : Slice) (off : Nat := 0) : Option UInt32 := do
  let b0 ← s.get? off
  let b1 ← s.get? (off + 1)
  let b2 ← s.get? (off + 2)
  let b3 ← s.get? (off + 3)
  return b0.toUInt32 ||| (b1.toUInt32 <<< 8) ||| (b2.toUInt32 <<< 16) ||| (b3.toUInt32 <<< 24)

private def hexDigit (n : Nat) : Char :=
  Char.ofNat (if n < 10 then '0'.toNat + n else 'a'.toNat + (n - 10))

/-- Hex dump for debugging (allocating). -/
def hexDump (s : Slice) : String :=
  Id.run do
    let mut out := ""
    for i in [:s.size] do
      let b := s.get! i |>.toNat
      if i > 0 then out := out.push ' '
      out := out.push (hexDigit (b / 16))
      out := out.push (hexDigit (b % 16))
    return out

end BE
end Bytes
