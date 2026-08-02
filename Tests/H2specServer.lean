/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Grpc.Metadata

/-- Minimal h2c server for h2spec (responds 200 to any request). -/
def main : IO Unit := do
  let port := ((← IO.getEnv "H2SPEC_PORT").getD "50051").toNat?.getD 50051 |>.toUInt16
  let handler : H2.StreamHandler := fun _ _headers _data endStream _headersSent => do
    if !endStream then return { finished := false }
    return {
      headers := #[
        ⟨Grpc.Metadata.ascii ":status", Grpc.Metadata.ascii "200"⟩,
        ⟨Grpc.Metadata.ascii "content-type", Grpc.Metadata.ascii "text/plain"⟩
      ]
      body := Grpc.Metadata.ascii "ok"
      finished := true
    }
  H2.Server.listen { host := "127.0.0.1", port } handler
