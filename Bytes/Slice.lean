/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace Bytes

/-- A view into a `ByteArray` without copying. -/
structure Slice where
  data : ByteArray
  start : Nat
  stop : Nat
  deriving Inhabited

namespace Slice

@[inline] def size (s : Slice) : Nat := s.stop - s.start

@[inline] def empty : Slice := ⟨ByteArray.empty, 0, 0⟩

@[inline] def ofByteArray (b : ByteArray) : Slice := ⟨b, 0, b.size⟩

@[inline] def isEmpty (s : Slice) : Bool := s.size == 0

/-- Bounds-checked byte access relative to the slice. -/
def get? (s : Slice) (i : Nat) : Option UInt8 :=
  if _h : i < s.size then
    some (s.data.get! (s.start + i))
  else
    none

def get! (s : Slice) (i : Nat) : UInt8 :=
  s.data.get! (s.start + i)

/-- Sub-slice; clamps to available range. -/
def sub (s : Slice) (off len : Nat) : Slice :=
  let start' := s.start + off
  let stop' := min s.stop (start' + len)
  if start' ≥ s.stop then ⟨s.data, s.stop, s.stop⟩
  else ⟨s.data, start', stop'⟩

/-- Materialize a copy (avoid on hot paths). -/
def toByteArray (s : Slice) : ByteArray :=
  s.data.extract s.start s.stop

/-- Append slice bytes into a growing array. -/
def appendTo (acc : ByteArray) (s : Slice) : ByteArray :=
  Id.run do
    let mut out := acc
    for i in [s.start:s.stop] do
      out := out.push (s.data.get! i)
    return out

/-- Compare two slices for byte equality. -/
def beq (a b : Slice) : Bool :=
  if a.size != b.size then false
  else Id.run do
    for i in [:a.size] do
      if a.get! i != b.get! i then return false
    return true

instance : BEq Slice where
  beq := beq

/-- ASCII decode only when needed (not hot path). -/
def toAsciiString (s : Slice) : String :=
  String.ofList (s.toByteArray.toList.map (fun b => Char.ofNat b.toNat))

/-- Build a slice from an ASCII string (allocation). -/
def ofAscii (s : String) : Slice :=
  ofByteArray (ByteArray.mk (s.toList.map (fun c => c.toNat.toUInt8)).toArray)

end Slice
end Bytes
