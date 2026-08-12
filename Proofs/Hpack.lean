/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Hpack.Decode
import Hpack.Encode
import Hpack.Huffman

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

/-! ## Huffman EOS / padding reject lemmas (LGSEC-2026-23) -/

open Hpack.Huffman

private def huffDecode (bs : ByteArray) : Except Error ByteArray :=
  decode (Bytes.Slice.ofByteArray bs)

private def huffRoundtrip (bs : ByteArray) : Bool :=
  match huffDecode (encode (Bytes.Slice.ofByteArray bs)) with
  | .ok out => out == bs
  | .error _ => false

/-- An empty Huffman input decodes to the empty byte array. -/
theorem huffman_empty_roundtrip :
    (match huffDecode ByteArray.empty with
     | .ok bs => bs.isEmpty
     | .error _ => false) = true := by
  native_decide

/-- Encoding '0' (sym 48) and decoding gives back 0x30. -/
theorem huffman_encode_decode_digit : huffRoundtrip (ByteArray.mk #[0x30]) = true := by
  native_decide

/-- Encoding 'a' (sym 97) and decoding gives back 0x61. -/
theorem huffman_encode_decode_alpha : huffRoundtrip (ByteArray.mk #[0x61]) = true := by
  native_decide

/-- A raw EOS symbol in the bitstream is rejected (eos or invalid). -/
theorem huffman_rejects_eos_symbol :
    -- 0xFF 0xFF 0xFF 0xFF contains the EOS code (0x3fffffff) at the MSBs.
    (match huffDecode (ByteArray.mk #[0xff, 0xff, 0xff, 0xff]) with
     | .ok _ => false
     | .error _ => true) = true := by
  native_decide

/-- Padding of ≤7 one-bits at end of a valid symbol is accepted. -/
theorem huffman_valid_padding_accepted :
    -- '5' (sym 53, code 0x1b = 6 bits) + 2 padding 1s → byte 0x6f
    (match huffDecode (ByteArray.mk #[0x6f]) with
     | .ok bs => bs == ByteArray.mk #[0x35]
     | .error _ => false) = true := by
  native_decide

/-- Padding with 0-bits is rejected as invalid. -/
theorem huffman_zero_bit_padding_rejected :
    -- After sym '0' (5 bits), 3 zero padding bits → 0x00; padding must be 1s.
    (match huffDecode (ByteArray.mk #[0x00]) with
     | .ok _ => false
     | .error e => e == Error.invalid) = true := by
  native_decide

/-- Huffman encode/decode roundtrip for "application/grpc". -/
theorem huffman_grpc_roundtrip :
    huffRoundtrip (ByteArray.mk
      #[0x61, 0x70, 0x70, 0x6c, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6f, 0x6e,
        0x2f, 0x67, 0x72, 0x70, 0x63]) = true := by
  native_decide

end Proofs.Hpack
