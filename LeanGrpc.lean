/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes
import Hpack
import H2
import Proto
import Grpc

/-- Umbrella library root. -/
def LeanGrpc.version : String :=
  s!"lean-grpc {Grpc.version} / h2 {H2.version} / hpack {Hpack.version}"
