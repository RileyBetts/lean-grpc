/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Examples.MirrorForge.Protocol

open Examples.MirrorForge.Protocol

/-- One forge mirror. Set `FORGE_ID` / `GRPC_PORT` (defaults: alpha / 50201). -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50201").toNat?.getD 50201 |>.toUInt16
  let forgeId := (← IO.getEnv "FORGE_ID").getD "alpha"
  let health ← IO.mkRef Grpc.Health.ServingStatus.serving
  let counters ← IO.mkRef ({} : Grpc.Channelz.Counters)
  let orca0 : Grpc.Orca.Report := {
    cpuUtilization := 0.42
    memUtilization := 0.33
    applicationUtilization := 0.11
  }
  let orcaRef ← IO.mkRef orca0
  let flakyLeft ← IO.mkRef (1 : Nat)  -- first Quench fails with UNAVAILABLE
  let logSink ← IO.mkRef (#[] : Array String)

  let chain : Array Grpc.Interceptor.ServerUnary := #[
    Grpc.Interceptor.loggingServer logSink
  ]

  let mut s := Grpc.Server.empty

  -- Stamp: token-gated unary through interceptor chain
  s := Grpc.Interceptor.registerUnary s serviceName "Stamp" chain fun reqBytes => do
    let req ← IO.ofExcept (StampRequest.decode reqBytes)
    if req.token != accessToken then
      Grpc.Channelz.recordFailure counters
      return (ByteArray.empty, Grpc.Status.unauthenticated "bad forge token")
    if req.billet.isEmpty then
      Grpc.Channelz.recordFailure counters
      return (ByteArray.empty, Grpc.Status.invalidArgument "empty billet")
    let report ← orcaRef.get
    let reply := StampReply.encode {
      forgeId
      mark := s!"{forgeId}:{req.billet}"
      cpuLoad := report.cpuUtilization
    }
    Grpc.Channelz.recordSuccess counters
    -- nudge ORCA load so OOB snapshots change over time
    orcaRef.set { report with applicationUtilization := report.applicationUtilization + 0.01 }
    return (reply, Grpc.Status.ok)

  -- Quench: flaky once → UNAVAILABLE (drives client retry policy)
  s := Grpc.Server.register s serviceName "Quench" fun _ => do
    let n ← flakyLeft.modifyGet fun n =>
      if n > 0 then (n, n - 1) else (0, 0)
    if n > 0 then
      Grpc.Channelz.recordFailure counters
      return (ByteArray.empty, Grpc.Status.unavailable "forge cooling")
    Grpc.Channelz.recordSuccess counters
    return ("quenched".toUTF8, Grpc.Status.ok)

  -- SlowStamp: sleeps ~400ms (hedge probe partner)
  s := Grpc.Server.register s serviceName "SlowStamp" fun reqBytes => do
    IO.sleep 400
    let req ← IO.ofExcept (StampRequest.decode reqBytes)
    Grpc.Channelz.recordSuccess counters
    return (StampReply.encode { forgeId, mark := s!"slow:{req.billet}", cpuLoad := 0.9 },
      Grpc.Status.ok)

  s := Grpc.Health.registerWithWatch s health
  s := Grpc.Reflection.register s #[
    serviceName,
    "grpc.health.v1.Health",
    "grpc.channelz.v1.Channelz",
    Grpc.Orca.oobService
  ]
  s := Grpc.Channelz.register s counters
  s := Grpc.Orca.registerOob s orcaRef

  IO.println s!"MirrorForge[{forgeId}] on 127.0.0.1:{port.toNat}"
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
