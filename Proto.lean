/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.Pool
import Proto.Wire
import Proto.Message
import Proto.RouteGuide
import Proto.WellKnown

/- Minimal protobuf wire codec for gRPC payloads.
   Prefer Lean-zh/protobuf when toolchain versions match; this module keeps
   lean-grpc self-contained on Lean 4.32+.
   Covers enums, nested, repeated, Any, map entries, oneof helpers. -/
namespace Proto
def version : String := "0.2.0-minimal"
end Proto
