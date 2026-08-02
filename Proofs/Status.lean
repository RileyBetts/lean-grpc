/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Status
import Grpc.Compression

namespace Proofs.Status

/-- Every `StatusCode` round-trips through the wire `UInt32` encoding. -/
theorem of_to (c : Grpc.StatusCode) :
    Grpc.StatusCode.ofUInt32 c.toUInt32 = c := by
  cases c <;> rfl

private theorem to_of_nat (k : Nat) (h : k ≤ 16) :
    (Grpc.StatusCode.ofUInt32 k.toUInt32).toUInt32 = k.toUInt32 := by
  match k with
  | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 => rfl
  | n + 17 =>
    have : n + 17 ≤ 16 := h
    omega

/-- In-range wire codes are stable under `ofUInt32` then `toUInt32`. -/
theorem to_of_le16 (n : UInt32) (h : n ≤ 16) :
    (Grpc.StatusCode.ofUInt32 n).toUInt32 = n := by
  have h16 : (16 : UInt32).toNat = 16 := by native_decide
  have hn : n.toNat ≤ 16 := by
    have : n.toNat ≤ (16 : UInt32).toNat := (UInt32.le_iff_toNat_le).1 h
    simpa [h16] using this
  simpa [UInt32.ofNat_toNat] using to_of_nat n.toNat hn

/-- Out-of-range wire codes map to `.unknown` (gRPC status code 2). -/
theorem of_gt16 (n : UInt32) (h : 16 < n) :
    Grpc.StatusCode.ofUInt32 n = .unknown := by
  have h16 : (16 : UInt32).toNat = 16 := by native_decide
  have hn : 16 < n.toNat := by
    have : (16 : UInt32).toNat < n.toNat := (UInt32.lt_iff_toNat_lt).1 h
    simpa [h16] using this
  simp only [Grpc.StatusCode.ofUInt32]
  split <;> first | omega | rfl

/-- Compression algorithm names round-trip through `parse?`. -/
theorem algorithm_parse_name (a : Grpc.Compression.Algorithm) :
    Grpc.Compression.Algorithm.parse? a.name = some a := by
  cases a <;> rfl

/-- Identity compression is the identity on payloads. -/
theorem compress_identity (p : ByteArray) :
    Grpc.Compression.compress .identity p = .ok p := rfl

theorem decompress_identity (p : ByteArray) :
    Grpc.Compression.decompress .identity p = .ok p := rfl

end Proofs.Status
