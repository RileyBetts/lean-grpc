/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Examples.Helloworld.Generated

/-- Typed helloworld client (stubs from `Generated.lean` / `./scripts/gen-helloworld.sh`). -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  let name := args[2]?.getD "Lean"
  let ch ← Grpc.Channel.connectH2c host port
  let stub : helloworld.GreeterStub := { channel := ch }
  match ← stub.SayHello { name } with
  | .error e =>
    IO.eprintln s!"rpc failed: {e}"
  | .ok reply =>
    IO.println reply.message
