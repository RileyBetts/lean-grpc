/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.BE
import Bytes.Pool
import Hpack.StaticTable
import Hpack.Huffman

namespace Hpack

structure HeaderField where
  name : ByteArray
  value : ByteArray
  deriving Inhabited, BEq

structure DynamicTable where
  entries : Array HeaderField
  size : Nat          -- current size in octets
  maxSize : Nat
  deriving Inhabited

namespace DynamicTable

def empty (maxSize : Nat := 4096) : DynamicTable :=
  ⟨#[], 0, maxSize⟩

def entrySize (h : HeaderField) : Nat :=
  h.name.size + h.value.size + 32

def evict (t : DynamicTable) : DynamicTable :=
  Id.run do
    let mut entries := t.entries
    let mut size := t.size
    while size > t.maxSize && entries.size > 0 do
      let last := entries.back!
      size := size - entrySize last
      entries := entries.pop
    return ⟨entries, size, t.maxSize⟩

def insert (t : DynamicTable) (h : HeaderField) : DynamicTable :=
  let es := entrySize h
  if es > t.maxSize then
    ⟨#[], 0, t.maxSize⟩
  else
    let t := { t with entries := #[h] ++ t.entries, size := t.size + es }
    evict t

/-- Absolute index: 1..staticSize static, then dynamic. -/
def get? (t : DynamicTable) (idx : Nat) : Option HeaderField :=
  match staticGet? idx with
  | some e => some ⟨e.name, e.value⟩
  | none =>
    let dynIdx := idx - staticTable.size - 1
    if dynIdx < t.entries.size then some t.entries[dynIdx]!
    else none

end DynamicTable

/-- Decode an integer with N-bit prefix (RFC 7541 §5.1). -/
def decodeInteger (s : Bytes.Slice) (off : Nat) (n : Nat) : Except String (Nat × Nat) := do
  if n == 0 ∨ n > 8 then throw "bad N"
  let b ← match s.get? off with
    | some x => pure x
    | none => throw "truncated int"
  let mask : UInt8 := (1 <<< n.toUInt8) - 1
  let mut i : Nat := (b &&& mask).toNat
  let mut pos := off + 1
  if i < mask.toNat then
    return (i, pos)
  let mut m : Nat := 0
  for _ in [:10] do
    let nb ← match s.get? pos with
      | some x => pure x
      | none => throw "truncated int"
    pos := pos + 1
    i := i + (nb &&& 127).toNat * (2 ^ m)
    m := m + 7
    if (nb &&& 128) == 0 then
      return (i, pos)
  throw "integer overflow"

/-- Encode integer with N-bit prefix into accumulator. -/
def encodeInteger (acc : ByteArray) (firstByte : UInt8) (n : Nat) (value : Nat) : ByteArray :=
  Id.run do
    let mask : Nat := (1 <<< n) - 1
    if value < mask then
      return acc.push (firstByte ||| value.toUInt8)
    else
      let mut out := acc.push (firstByte ||| mask.toUInt8)
      let mut v := value - mask
      while v ≥ 128 do
        out := out.push ((v % 128) + 128).toUInt8
        v := v / 128
      return out.push v.toUInt8

/-- Decode a string literal (Huffman or raw). -/
def decodeString (s : Bytes.Slice) (off : Nat) : Except String (ByteArray × Nat) := do
  let b ← s.get? off |>.elim (throw "truncated string") pure
  let huffman := (b &&& 128) != 0
  let (len, pos) ← decodeInteger s off 7
  if pos + len > s.size then throw "truncated string data"
  let raw := s.sub pos len
  let bytes ←
    if huffman then
      match Huffman.decode raw with
      | .ok b => pure b
      | .error _ => throw "huffman decode failed"
    else
      pure raw.toByteArray
  return (bytes, pos + len)

end Hpack
