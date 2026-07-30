/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.Pool
import Proto.Wire
import Proto.Message
import Proto.RouteGuide

/- Minimal protobuf wire codec for gRPC payloads.
   Prefer Lean-zh/protobuf when toolchain versions match; this module keeps
   lean-grpc self-contained on Lean 4.32+.
   Covers enums, nested messages, repeated (packed + unpacked) as needed by
   interop + RouteGuide. -/
namespace Proto
def version : String := "0.1.0-minimal"
end Proto
