/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Init.Data.ByteArray.Lemmas
import Grpc.Message
import Proofs.BytesBE

namespace Proofs.Message

open Grpc Bytes

/-- Identity compression framing is `0 ‖ BE(len) ‖ payload`. -/
theorem encode_identity (p : ByteArray) :
    Message.encode p .identity =
      .ok (ByteArray.empty.push 0 ++ BE.u32Bytes p.size.toUInt32 ++ p) := by
  unfold Message.encode
  simp [Compression.compress, Pool.pushBytes]
  rfl

theorem encodeId_eq (p : ByteArray) :
    Message.encodeId p =
      ByteArray.empty.push 0 ++ BE.u32Bytes p.size.toUInt32 ++ p := by
  simp [Message.encodeId, encode_identity]

private def frameHdr (p : ByteArray) : ByteArray :=
  ByteArray.empty.push 0 ++ BE.u32Bytes p.size.toUInt32

theorem encodeId_eq' (p : ByteArray) : Message.encodeId p = frameHdr p ++ p := by
  simp [encodeId_eq, frameHdr]

theorem frameHdr_size (p : ByteArray) : (frameHdr p).size = 5 := by
  simp [frameHdr, ByteArray.size_append, ByteArray.size_push, ByteArray.size_empty,
        Proofs.BytesBE.u32Bytes_size]

/-- Identity frames are always 5 + payload bytes. -/
theorem encodeId_size (p : ByteArray) :
    (Message.encodeId p).size = 5 + p.size := by
  simp [encodeId_eq', ByteArray.size_append, frameHdr_size]

theorem frameHdr_data_get0 (p : ByteArray) : (frameHdr p).data[0]! = 0 := by
  unfold frameHdr
  rw [ByteArray.data_append, ByteArray.data_push, ByteArray.data_empty]
  rfl

/-- Compressed-flag byte is 0 for identity encode. -/
theorem encodeId_flag (p : ByteArray) : (Message.encodeId p).get! 0 = 0 := by
  rw [encodeId_eq', ByteArray.get!, ByteArray.data_append]
  have hsz : (frameHdr p).data.size = 5 := frameHdr_size p
  have hlt : 0 < (frameHdr p).data.size := by omega
  have htot : 0 < ((frameHdr p).data ++ p.data).size := by
    rw [Array.size_append, hsz]; omega
  rw [getElem!_pos (c := (frameHdr p).data ++ p.data) (i := 0) htot]
  rw [Array.getElem_append_left (h := htot) (hlt := hlt)]
  rw [← getElem!_pos (frameHdr p).data 0 hlt]
  exact frameHdr_data_get0 p

theorem frameHdr_data_get_len (p : ByteArray) (i : Nat) (hi : i < 4) :
    (frameHdr p).data[1 + i]! = (BE.u32Bytes p.size.toUInt32).data[i]! := by
  unfold frameHdr
  rw [ByteArray.data_append, ByteArray.data_push, ByteArray.data_empty]
  let left : Array UInt8 := Array.empty.push 0
  change (left ++ (BE.u32Bytes p.size.toUInt32).data)[1 + i]! =
    (BE.u32Bytes p.size.toUInt32).data[i]!
  have hulen : (BE.u32Bytes p.size.toUInt32).data.size = 4 :=
    Proofs.BytesBE.u32Bytes_size p.size.toUInt32
  have left_size : left.size = 1 := rfl
  have hle : left.size ≤ 1 + i := by omega
  have htot : 1 + i < (left ++ (BE.u32Bytes p.size.toUInt32).data).size := by
    rw [Array.size_append, left_size, hulen]; omega
  rw [getElem!_pos (c := left ++ (BE.u32Bytes p.size.toUInt32).data) (i := 1 + i) htot]
  rw [Array.getElem_append_right (h := htot) (hle := hle)]
  have hsub : 1 + i - left.size = i := by omega
  have hsublt : 1 + i - left.size < (BE.u32Bytes p.size.toUInt32).data.size := by omega
  rw [← getElem!_pos (BE.u32Bytes p.size.toUInt32).data (1 + i - left.size) hsublt]
  rw [hsub]

theorem encodeId_len_get (p : ByteArray) (i : Nat) (hi : i < 4) :
    (Message.encodeId p).get! (1 + i) = (BE.u32Bytes p.size.toUInt32).get! i := by
  rw [encodeId_eq', ByteArray.get!, ByteArray.data_append]
  have hsz : (frameHdr p).data.size = 5 := frameHdr_size p
  have hlt : 1 + i < (frameHdr p).data.size := by omega
  have htot : 1 + i < ((frameHdr p).data ++ p.data).size := by
    rw [Array.size_append, hsz]; omega
  rw [getElem!_pos (c := (frameHdr p).data ++ p.data) (i := 1 + i) htot]
  rw [Array.getElem_append_left (h := htot) (hlt := hlt)]
  rw [← getElem!_pos (frameHdr p).data (1 + i) hlt]
  simpa [ByteArray.get!] using frameHdr_data_get_len p i hi

/-- Payload bytes sit immediately after the 5-byte header. -/
theorem encodeId_payload_get (p : ByteArray) (i : Nat) (hi : i < p.size) :
    (Message.encodeId p).get! (5 + i) = p.get! i := by
  rw [encodeId_eq', ByteArray.get!, ByteArray.data_append]
  have hsz : (frameHdr p).data.size = 5 := frameHdr_size p
  have hle : (frameHdr p).data.size ≤ 5 + i := by omega
  have htot : 5 + i < ((frameHdr p).data ++ p.data).size := by
    rw [Array.size_append, hsz]; exact Nat.add_lt_add_left hi 5
  rw [getElem!_pos (c := (frameHdr p).data ++ p.data) (i := 5 + i) htot]
  rw [Array.getElem_append_right (h := htot) (hle := hle)]
  have hsub : 5 + i - (frameHdr p).data.size = i := by omega
  simp only [hsub]
  exact Eq.symm (getElem!_pos p.data i hi)

/-- Length prefix of an identity frame decodes to `payload.size` (mod 2³²). -/
theorem encodeId_readLen (p : ByteArray) :
    BE.readU32 (Slice.ofByteArray (Message.encodeId p)) 1 = some p.size.toUInt32 := by
  have hs := encodeId_size p
  have g0 : Slice.get? (Slice.ofByteArray (Message.encodeId p)) 1 =
      some ((BE.u32Bytes p.size.toUInt32).get! 0) := by
    have hlt : 1 < 5 + p.size := by omega
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs, hlt, encodeId_len_get p 0 (by decide)]
  have g1 : Slice.get? (Slice.ofByteArray (Message.encodeId p)) 2 =
      some ((BE.u32Bytes p.size.toUInt32).get! 1) := by
    have hlt : 2 < 5 + p.size := by omega
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs, hlt, encodeId_len_get p 1 (by decide)]
  have g2 : Slice.get? (Slice.ofByteArray (Message.encodeId p)) 3 =
      some ((BE.u32Bytes p.size.toUInt32).get! 2) := by
    have hlt : 3 < 5 + p.size := by omega
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs, hlt, encodeId_len_get p 2 (by decide)]
  have g3 : Slice.get? (Slice.ofByteArray (Message.encodeId p)) 4 =
      some ((BE.u32Bytes p.size.toUInt32).get! 3) := by
    have hlt : 4 < 5 + p.size := by omega
    simp [Slice.get?, Slice.ofByteArray, Slice.size, hs, hlt, encodeId_len_get p 3 (by decide)]
  have e0 : (BE.u32Bytes p.size.toUInt32).get! 0 = (p.size.toUInt32 >>> 24).toUInt8 := rfl
  have e1 : (BE.u32Bytes p.size.toUInt32).get! 1 = (p.size.toUInt32 >>> 16).toUInt8 := rfl
  have e2 : (BE.u32Bytes p.size.toUInt32).get! 2 = (p.size.toUInt32 >>> 8).toUInt8 := rfl
  have e3 : (BE.u32Bytes p.size.toUInt32).get! 3 = p.size.toUInt32.toUInt8 := rfl
  simp only [BE.readU32, g0, g1, g2, g3, e0, e1, e2, e3]
  exact congrArg some (Proofs.BytesBE.u32_bytes_reconstitute _)

private def decodeOk (p : ByteArray) : Bool :=
  match Message.decodeOne (Slice.ofByteArray (Message.encodeId p)) (allowGzip := false) with
  | .ok (p', rest) => p' == p && rest.isEmpty
  | .error _ => false

/-- Kernel-checked identity encode/decode roundtrips on representative payloads. -/
theorem encodeId_decodeOne_empty : decodeOk ByteArray.empty = true := by native_decide
theorem encodeId_decodeOne_one : decodeOk (ByteArray.mk #[0x2a]) = true := by native_decide
theorem encodeId_decodeOne_four :
    decodeOk (ByteArray.mk #[1, 2, 3, 4]) = true := by native_decide
theorem encodeId_decodeOne_ascii :
    decodeOk (ByteArray.mk #[104, 101, 108, 108, 111]) = true := by native_decide

end Proofs.Message
