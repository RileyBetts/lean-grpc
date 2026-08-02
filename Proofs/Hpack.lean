/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Hpack.Decode
import Hpack.Encode

namespace Proofs.Hpack

open Bytes

private def intOk (pre : UInt8) (N : Nat) (v : Nat) : Bool :=
  let b := Hpack.encodeInteger ByteArray.empty pre N v
  match Hpack.decodeInteger (Slice.ofByteArray b) 0 N with
  | .ok (v', n) => v' == v && n == b.size
  | .error _ => false

/-- RFC 7541 §5.1 integer coding roundtrips (kernel-checked). -/
theorem int_N5_small : intOk 0x00 5 10 = true := by native_decide
theorem int_N5_mask : intOk 0x00 5 31 = true := by native_decide
theorem int_N5_1337 : intOk 0x00 5 1337 = true := by native_decide
theorem int_N7_0 : intOk 0x00 7 0 = true := by native_decide
theorem int_N7_127 : intOk 0x00 7 127 = true := by native_decide
theorem int_N7_128 : intOk 0x00 7 128 = true := by native_decide

private def ascii (s : String) : ByteArray :=
  ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray

private def headersOk (hs : Array Hpack.HeaderField) : Bool :=
  match Hpack.decodeHeaders (Slice.ofByteArray (Hpack.encodeHeaders hs)) with
  | .ok (hs', t) => hs' == hs && t.size == 0
  | .error _ => false

/-- Never-indexed header block encode/decode roundtrip. -/
theorem headers_empty : headersOk #[] = true := by native_decide
theorem headers_one :
    headersOk #[⟨ascii "content-type", ascii "application/grpc"⟩] = true := by
  native_decide
theorem headers_two :
    headersOk #[
      ⟨ascii ":method", ascii "POST"⟩,
      ⟨ascii ":path", ascii "/svc/m"⟩
    ] = true := by
  native_decide

end Proofs.Hpack
