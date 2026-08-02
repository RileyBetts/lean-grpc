/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Init.Data.ByteArray.Lemmas
import Init.Data.UInt.Lemmas
import Std.Tactic.BVDecide
import Bytes.BE
import Bytes.Pool

namespace Proofs.BytesBE

open Bytes

theorem u32_bytes_reconstitute (n : UInt32) :
    ((n >>> 24).toUInt8.toUInt32 <<< 24) |||
      ((n >>> 16).toUInt8.toUInt32 <<< 16) |||
      ((n >>> 8).toUInt8.toUInt32 <<< 8) |||
      n.toUInt8.toUInt32 = n := by
  apply UInt32.eq_of_toBitVec_eq
  bv_decide

theorem u32Bytes_size (n : UInt32) : (BE.u32Bytes n).size = 4 := by
  simp [BE.u32Bytes, ByteArray.size]

/-- Big-endian `u32` encode/decode is the identity. -/
theorem read_u32Bytes (n : UInt32) :
    BE.readU32 (Slice.ofByteArray (BE.u32Bytes n)) 0 = some n := by
  have hs := u32Bytes_size n
  have g0 : Slice.get? (Slice.ofByteArray (BE.u32Bytes n)) 0 = some ((BE.u32Bytes n).get! 0) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have g1 : Slice.get? (Slice.ofByteArray (BE.u32Bytes n)) 1 = some ((BE.u32Bytes n).get! 1) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have g2 : Slice.get? (Slice.ofByteArray (BE.u32Bytes n)) 2 = some ((BE.u32Bytes n).get! 2) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have g3 : Slice.get? (Slice.ofByteArray (BE.u32Bytes n)) 3 = some ((BE.u32Bytes n).get! 3) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have e0 : (BE.u32Bytes n).get! 0 = (n >>> 24).toUInt8 := rfl
  have e1 : (BE.u32Bytes n).get! 1 = (n >>> 16).toUInt8 := rfl
  have e2 : (BE.u32Bytes n).get! 2 = (n >>> 8).toUInt8 := rfl
  have e3 : (BE.u32Bytes n).get! 3 = n.toUInt8 := rfl
  simp only [BE.readU32, g0, g1, g2, g3, e0, e1, e2, e3]
  exact congrArg some (u32_bytes_reconstitute n)

theorem u24_bytes_reconstitute (n : UInt32) :
    ((n >>> 16).toUInt8.toUInt32 <<< 16) |||
      ((n >>> 8).toUInt8.toUInt32 <<< 8) |||
      n.toUInt8.toUInt32 = n &&& 0xffffff := by
  apply UInt32.eq_of_toBitVec_eq
  bv_decide

theorem u24Bytes_size (n : UInt32) : (BE.u24Bytes n).size = 3 := by
  simp [BE.u24Bytes, ByteArray.size]

/-- HTTP/2 length field: encode/decode recovers the low 24 bits. -/
theorem read_u24Bytes (n : UInt32) :
    BE.readU24 (Slice.ofByteArray (BE.u24Bytes n)) 0 = some (n &&& 0xffffff) := by
  have hs := u24Bytes_size n
  have g0 : Slice.get? (Slice.ofByteArray (BE.u24Bytes n)) 0 = some ((BE.u24Bytes n).get! 0) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have g1 : Slice.get? (Slice.ofByteArray (BE.u24Bytes n)) 1 = some ((BE.u24Bytes n).get! 1) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have g2 : Slice.get? (Slice.ofByteArray (BE.u24Bytes n)) 2 = some ((BE.u24Bytes n).get! 2) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have e0 : (BE.u24Bytes n).get! 0 = (n >>> 16).toUInt8 := rfl
  have e1 : (BE.u24Bytes n).get! 1 = (n >>> 8).toUInt8 := rfl
  have e2 : (BE.u24Bytes n).get! 2 = n.toUInt8 := rfl
  simp only [BE.readU24, g0, g1, g2, e0, e1, e2]
  exact congrArg some (u24_bytes_reconstitute n)

theorem u16_bytes_reconstitute (n : UInt16) :
    ((n >>> 8).toUInt8.toUInt16 <<< 8) ||| n.toUInt8.toUInt16 = n := by
  apply UInt16.eq_of_toBitVec_eq
  bv_decide

theorem u16Bytes_size (n : UInt16) : (BE.u16Bytes n).size = 2 := by
  simp [BE.u16Bytes, ByteArray.size]

theorem read_u16Bytes (n : UInt16) :
    BE.readU16 (Slice.ofByteArray (BE.u16Bytes n)) 0 = some n := by
  have hs := u16Bytes_size n
  have g0 : Slice.get? (Slice.ofByteArray (BE.u16Bytes n)) 0 = some ((BE.u16Bytes n).get! 0) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have g1 : Slice.get? (Slice.ofByteArray (BE.u16Bytes n)) 1 = some ((BE.u16Bytes n).get! 1) := by
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs]
  have e0 : (BE.u16Bytes n).get! 0 = (n >>> 8).toUInt8 := rfl
  have e1 : (BE.u16Bytes n).get! 1 = n.toUInt8 := rfl
  simp only [BE.readU16, g0, g1, e0, e1]
  exact congrArg some (u16_bytes_reconstitute n)

theorem pushBytes_eq_append (acc bs : ByteArray) :
    Bytes.Pool.pushBytes acc bs = acc ++ bs := rfl

end Proofs.BytesBE
