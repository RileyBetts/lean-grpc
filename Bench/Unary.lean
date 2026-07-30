/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Simple unary latency microbench against a local server (start server separately). -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  let n := (args[2]?.getD "100").toNat?.getD 100
  let ch ← Grpc.Channel.connectH2c host port
  let req := Proto.HelloRequest.encode { name := "bench" }
  let start ← IO.monoMsNow
  for _ in [:n] do
    let res ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello" req
    if res.status.code != .ok then throw (IO.userError "rpc fail")
  let stop ← IO.monoMsNow
  let elapsed := stop - start
  IO.println s!"unary n={n} elapsed_ms={elapsed} avg_ms={elapsed / n}"
