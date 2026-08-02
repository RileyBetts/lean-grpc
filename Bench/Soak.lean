/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-! # `rpc_soak` / `channel_soak`-style soak test.

    Mirrors the flag surface of grpc's standard soak tests (see
    `grpc/test/cpp/interop/interop_client.cc`'s `--soak_*` flags), adapted to this repo's
    positional-arg CLI convention: `host port [--flag=value ...]`.

    Supported flags (defaults match upstream where sensible):
    - `--soak_iterations=N` (default 10): number of unary RPCs to issue.
    - `--soak_max_failures=N` (default 0): failures (error status, timeout, or a call slower
      than `soak_per_iteration_max_acceptable_latency_ms`) tolerated before the run fails.
    - `--soak_per_iteration_max_acceptable_latency_ms=N` (default 1000): a call slower than
      this counts as a soak failure even if its status is OK.
    - `--soak_min_time_ms_between_rpcs=N` (default 0): minimum spacing between RPC starts.
    - `--soak_overall_timeout_seconds=N` (default 10): stop issuing new RPCs once elapsed.
    - `--soak_request_size=N` (default 0/unset): pad the `HelloRequest.name` field with `x`s
      so the encoded request is approximately this many bytes (best-effort — this demo
      service only has one string field to grow).
    - `--soak_num_channels=N` (default 1): open this many channels and round-robin RPCs
      across them (channel_soak). `1` reproduces plain `rpc_soak` (single shared channel).
    - `--soak_reset_channel_per_iteration=true|false` (default false): reconnect the channel
      used by each iteration before issuing its RPC (channel_soak's connection-churn mode). -/

structure SoakFlags where
  iterations : Nat := 10
  maxFailures : Nat := 0
  perIterationMaxLatencyMs : Nat := 1000
  minTimeMsBetweenRpcs : Nat := 0
  overallTimeoutSeconds : Nat := 10
  requestSize : Nat := 0
  numChannels : Nat := 1
  resetChannelPerIteration : Bool := false
  deriving Inhabited

private def parseFlag (flags : SoakFlags) (arg : String) : SoakFlags :=
  if !("--".isPrefixOf arg) then flags
  else
    match (arg.drop 2).toString.splitOn "=" with
    | [key, value] =>
      match key with
      | "soak_iterations" => { flags with iterations := value.toNat?.getD flags.iterations }
      | "soak_max_failures" => { flags with maxFailures := value.toNat?.getD flags.maxFailures }
      | "soak_per_iteration_max_acceptable_latency_ms" =>
        { flags with perIterationMaxLatencyMs := value.toNat?.getD flags.perIterationMaxLatencyMs }
      | "soak_min_time_ms_between_rpcs" =>
        { flags with minTimeMsBetweenRpcs := value.toNat?.getD flags.minTimeMsBetweenRpcs }
      | "soak_overall_timeout_seconds" =>
        { flags with overallTimeoutSeconds := value.toNat?.getD flags.overallTimeoutSeconds }
      | "soak_request_size" => { flags with requestSize := value.toNat?.getD flags.requestSize }
      | "soak_num_channels" => { flags with numChannels := max 1 (value.toNat?.getD flags.numChannels) }
      | "soak_reset_channel_per_iteration" => { flags with resetChannelPerIteration := value == "true" }
      | _ => flags
    | _ => flags

private def paddedName (size : Nat) : String :=
  if size == 0 then "soak"
  else String.ofList (List.replicate size 'x')

/-- rpc_soak / channel_soak: N unary RPCs across `soak_num_channels` channels, enforcing
    per-call latency + overall failure-count + overall wall-clock budgets. -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  -- Back-compat: a bare positional third arg (old `benchSoak host port N` calling
  -- convention) sets `soak_iterations`; anything `--flag=value`-shaped is parsed normally.
  let (legacyIterations?, flagArgs) :=
    match args[2]? with
    | some a =>
      if !("--".isPrefixOf a) then (a.toNat?, args.drop 3)
      else (none, args.drop 2)
    | none => (none, [])
  let flags := flagArgs.foldl parseFlag { iterations := legacyIterations?.getD 10 }

  let mut channels : Array Grpc.Channel := #[]
  for _ in [:flags.numChannels] do
    channels := channels.push (← Grpc.Channel.connectH2c host port)

  let req := Proto.HelloRequest.encode { name := paddedName flags.requestSize }
  let mut ok : Nat := 0
  let mut fail : Nat := 0
  let mut worstLatencyMs : Nat := 0
  let t0 ← IO.monoMsNow
  let deadlineMs := t0 + flags.overallTimeoutSeconds * 1000

  for i in [:flags.iterations] do
    let now ← IO.monoMsNow
    if now >= deadlineMs then break
    if flags.minTimeMsBetweenRpcs > 0 && i > 0 then
      IO.sleep flags.minTimeMsBetweenRpcs.toUInt32
    let idx := i % channels.size
    if flags.resetChannelPerIteration then
      let fresh ← Grpc.Channel.connectH2c host port
      channels := channels.modify idx (fun _ => fresh)
    match channels[idx]? with
    | none => fail := fail + 1
    | some chan =>
      let callStart ← IO.monoMsNow
      try
        let res ← Grpc.Channel.unary chan "helloworld.Greeter" "SayHello" req
        let latency := (← IO.monoMsNow) - callStart
        worstLatencyMs := max worstLatencyMs latency
        if res.status.code == .ok && latency <= flags.perIterationMaxLatencyMs then
          ok := ok + 1
        else
          fail := fail + 1
      catch _ =>
        fail := fail + 1

  let t1 ← IO.monoMsNow
  IO.println s!"soak channels={channels.size} iterations={flags.iterations} ok={ok} fail={fail} \
worst_latency_ms={worstLatencyMs} elapsed_ms={t1 - t0}"
  if fail > flags.maxFailures then
    throw (IO.userError s!"soak failures {fail} exceeded soak_max_failures={flags.maxFailures}")
  IO.println "soak OK"
