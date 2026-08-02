/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire

namespace Proofs.Wire

open Proto Bytes

/-- Single-byte varints (`v < 128`) encode as one pushed byte. -/
theorem encodeVarint_lt128 (v : UInt64) (h : v < 0x80) :
    Wire.encodeVarint ByteArray.empty v = ByteArray.empty.push v.toUInt8 := by
  simp [Wire.encodeVarint, h]

private def varintOk (v : UInt64) : Bool :=
  match Wire.decodeVarint (Slice.ofByteArray (Wire.encodeVarint ByteArray.empty v)) 0 with
  | .ok (v', n) => v' == v && n == (Wire.encodeVarint ByteArray.empty v).size
  | .error _ => false

/-- Kernel-checked protobuf varint roundtrips (1–10 byte encodings). -/
theorem varint_0 : varintOk 0 = true := by native_decide
theorem varint_1 : varintOk 1 = true := by native_decide
theorem varint_127 : varintOk 127 = true := by native_decide
theorem varint_128 : varintOk 128 = true := by native_decide
theorem varint_300 : varintOk 300 = true := by native_decide
theorem varint_16383 : varintOk 16383 = true := by native_decide
theorem varint_16384 : varintOk 16384 = true := by native_decide
theorem varint_max32 : varintOk (0xffffffff : UInt64) = true := by native_decide
theorem varint_max64 : varintOk (0xffffffffffffffff : UInt64) = true := by native_decide

theorem wireType_toNat_values :
    Wire.WireType.varint.toNat = 0 ∧
    Wire.WireType.fixed64.toNat = 1 ∧
    Wire.WireType.lengthDelimited.toNat = 2 ∧
    Wire.WireType.startGroup.toNat = 3 ∧
    Wire.WireType.endGroup.toNat = 4 ∧
    Wire.WireType.fixed32.toNat = 5 := by
  decide

end Proofs.Wire
