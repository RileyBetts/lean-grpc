/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Metadata

namespace Proofs.Metadata

open Grpc

private def percentOk (s : String) : Bool :=
  Metadata.percentDecode (Metadata.percentEncode s) == s

private def base64Ok (d : ByteArray) : Bool :=
  match Metadata.base64Decode (Metadata.base64Encode d) with
  | .ok d' => d' == d
  | .error _ => false

/-- Percent-encoding roundtrip (grpc-message). -/
theorem percent_ascii : percentOk "hello-world._~" = true := by native_decide
theorem percent_space : percentOk "a b" = true := by native_decide
theorem percent_utf8 : percentOk "BMP ☺ emoji 😈" = true := by native_decide
theorem percent_empty : percentOk "" = true := by native_decide

/-- Base64 roundtrip (-bin metadata). -/
theorem base64_empty : base64Ok ByteArray.empty = true := by native_decide
theorem base64_one : base64Ok (ByteArray.mk #[0]) = true := by native_decide
theorem base64_two : base64Ok (ByteArray.mk #[0x01, 0x02]) = true := by native_decide
theorem base64_three : base64Ok (ByteArray.mk #[1, 2, 3]) = true := by native_decide
theorem base64_four : base64Ok (ByteArray.mk #[1, 2, 3, 4]) = true := by native_decide

/-- gRPC timeout grammar unit table. -/
theorem parseTimeoutMs_empty : Metadata.parseTimeoutMs "" = none := by native_decide
theorem parseTimeoutMs_10S : Metadata.parseTimeoutMs "10S" = some 10000 := by native_decide
theorem parseTimeoutMs_1H : Metadata.parseTimeoutMs "1H" = some 3600000 := by native_decide
theorem parseTimeoutMs_5M : Metadata.parseTimeoutMs "5M" = some 300000 := by native_decide
theorem parseTimeoutMs_100m : Metadata.parseTimeoutMs "100m" = some 100 := by native_decide
theorem parseTimeoutMs_1500u : Metadata.parseTimeoutMs "1500u" = some 1 := by native_decide
theorem parseTimeoutMs_1n : Metadata.parseTimeoutMs "1n" = some 0 := by native_decide
theorem parseTimeoutMs_bad : Metadata.parseTimeoutMs "10X" = none := by native_decide

/-- `toString n ++ "S"` parses as `n * 1000` for concrete values (kernel-checked). -/
theorem parseTimeoutMs_S_0 : Metadata.parseTimeoutMs "0S" = some 0 := by native_decide
theorem parseTimeoutMs_S_1 : Metadata.parseTimeoutMs "1S" = some 1000 := by native_decide
theorem parseTimeoutMs_S_42 : Metadata.parseTimeoutMs "42S" = some 42000 := by native_decide

end Proofs.Metadata
