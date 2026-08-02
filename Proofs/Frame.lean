/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Init.Data.ByteArray.Lemmas
import H2.Frame
import Proofs.BytesBE

namespace Proofs.Frame

open H2
open Bytes

/-- Named HTTP/2 frame types round-trip through the type byte. -/
theorem frameType_of_to_named (t : FrameType) (h : ∀ n, t ≠ .unknown n) :
    FrameType.ofU8 t.toU8 = t := by
  cases t with
  | unknown n => exact absurd rfl (h n)
  | _ => rfl

/-- Unknown type bytes outside 0..9 round-trip as `.unknown`. -/
theorem frameType_of_to_unknown (n : UInt8) (h : 9 < n.toNat) :
    FrameType.ofU8 (FrameType.unknown n).toU8 = .unknown n := by
  simp only [FrameType.ofU8, FrameType.toU8]
  split <;> first | omega | rfl

private theorem frameType_to_of_nat (k : Nat) (h : k ≤ 9) :
    (FrameType.ofU8 k.toUInt8).toU8 = k.toUInt8 := by
  match k with
  | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 => rfl
  | n + 10 =>
    have : n + 10 ≤ 9 := h
    omega

theorem frameType_to_of_le9 (n : UInt8) (h : n.toNat ≤ 9) :
    (FrameType.ofU8 n).toU8 = n := by
  have := frameType_to_of_nat n.toNat h
  simpa [UInt8.ofNat_toNat] using this

private def frameOk (f : Frame) : Bool :=
  match Frame.decode (Slice.ofByteArray (Frame.encode f)) with
  | .ok (f', n) =>
      f'.type == FrameType.ofU8 f.type.toU8 &&
      f'.flags == f.flags &&
      f'.streamId == (f.streamId &&& 0x7fffffff) &&
      f'.payload == f.payload &&
      n == (Frame.encode f).size
  | .error _ => false

/-- Kernel-checked HTTP/2 frame encode/decode roundtrips. -/
theorem frame_empty_data :
    frameOk ⟨.data, Flags.none, 1, ByteArray.empty⟩ = true := by native_decide

theorem frame_ping :
    frameOk ⟨.ping, Flags.ack, 0, ByteArray.mk #[0,1,2,3,4,5,6,7]⟩ = true := by
  native_decide

theorem frame_headers_payload :
    frameOk ⟨.headers, Flags.endHeaders, 3, ByteArray.mk #[0x82]⟩ = true := by
  native_decide

theorem frame_window_update :
    frameOk (Frame.windowUpdate 5 1024) = true := by native_decide

theorem frame_settings_ack :
    frameOk Frame.settingsAck = true := by native_decide

theorem encode_size_empty_data :
    (Frame.encode ⟨.data, Flags.none, 1, ByteArray.empty⟩).size = 9 := by
  native_decide

end Proofs.Frame
