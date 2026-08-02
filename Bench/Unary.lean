/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Simple unary latency microbench against a local server (start server separately).
    Prints avg and a coarse p50/p99 from per-call samples. -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  let n := (args[2]?.getD "100").toNat?.getD 100
  let ch ← Grpc.Channel.connectH2c host port
  let req := Proto.HelloRequest.encode { name := "bench" }
  let mut samples : Array Nat := #[]
  let start ← IO.monoMsNow
  for _ in [:n] do
    let t0 ← IO.monoMsNow
    let res ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello" req
    if res.status.code != .ok then throw (IO.userError "rpc fail")
    let t1 ← IO.monoMsNow
    samples := samples.push (t1 - t0)
  let stop ← IO.monoMsNow
  let elapsed := stop - start
  let sorted := samples.insertionSort (· ≤ ·)
  let p50 := sorted[n / 2]!
  let p99Idx := min ((n * 99) / 100) (n - 1)
  let p99 := sorted[p99Idx]!
  IO.println s!"unary n={n} elapsed_ms={elapsed} avg_ms={elapsed / n} p50_ms={p50} p99_ms={p99}"
  IO.println "Compare later against a tonic peer on the same host; record in docs/conformance.md."
