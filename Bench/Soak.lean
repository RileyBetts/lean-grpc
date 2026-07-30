/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Lightweight rpc_soak: N unary RPCs; fails if error rate exceeds threshold. -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  let n := (args[2]?.getD "50").toNat?.getD 50
  let ch ← Grpc.Channel.connectH2c host port
  let req := Proto.HelloRequest.encode { name := "soak" }
  let mut ok : Nat := 0
  let mut fail : Nat := 0
  let t0 ← IO.monoMsNow
  for _ in [:n] do
    try
      let res ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello" req
      if res.status.code == .ok then ok := ok + 1 else fail := fail + 1
    catch _ =>
      fail := fail + 1
  let t1 ← IO.monoMsNow
  IO.println s!"soak n={n} ok={ok} fail={fail} elapsed_ms={t1 - t0}"
  if fail > 0 then throw (IO.userError s!"soak failures {fail}")
  IO.println "soak OK"
