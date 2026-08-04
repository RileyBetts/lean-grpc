/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Examples.MirrorForge.Protocol

open Examples.MirrorForge.Protocol

/-- Accept forge credentials from Bearer metadata **or** body `token` (fallback for
    existing h2c MirrorForge clients). Under mTLS, `requirePeerIdentity` may also
    sit on the interceptor chain. -/
private def authorized (ctx : Grpc.ServerCallContext) (bodyToken : String) : Bool :=
  match ctx.metadata.get? "authorization" with
  | some auth =>
      auth == s!"Bearer {accessToken}" || bodyToken == accessToken
  | none =>
      bodyToken == accessToken

/-- One forge mirror. Set `FORGE_ID` / `GRPC_PORT` (defaults: alpha / 50201).

    TLS (optional):
    * `TLS_CERT` / `TLS_KEY` — serve with in-process TLS+ALPN `h2`
    * `TLS_CLIENT_CA` — require and verify client certs (mTLS); Stamp uses
      `requirePeerIdentity` and embeds peer CN in the stamp mark when present -/
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

  let cert := (← IO.getEnv "TLS_CERT").getD ""
  let key := (← IO.getEnv "TLS_KEY").getD ""
  let clientCa ← IO.getEnv "TLS_CLIENT_CA"
  let useTls := !cert.isEmpty && !key.isEmpty
  let mtls := useTls && clientCa.isSome

  let mut chain : Array Grpc.Interceptor.ServerUnaryWithContext :=
    #[Grpc.Interceptor.loggingServerWithContext logSink]
  if mtls then
    chain := chain.push Grpc.Interceptor.requirePeerIdentity

  let mut s := Grpc.Server.empty

  -- Stamp: context-aware unary (Bearer metadata preferred; body token fallback)
  s := Grpc.Interceptor.registerUnaryWithContext s serviceName "Stamp" chain fun ctx reqBytes => do
    let req ← IO.ofExcept (StampRequest.decode reqBytes)
    if !(authorized ctx req.token) then
      Grpc.Channelz.recordFailure counters
      return (ByteArray.empty, Grpc.Status.unauthenticated "bad forge token")
    if req.billet.isEmpty then
      Grpc.Channelz.recordFailure counters
      return (ByteArray.empty, Grpc.Status.invalidArgument "empty billet")
    let report ← orcaRef.get
    let peerCn :=
      match ctx.peerIdentity with
      | some id => id.commonName
      | none => ""
    let mark :=
      if peerCn.isEmpty then s!"{forgeId}:{req.billet}"
      else s!"{forgeId}:{peerCn}:{req.billet}"
    let reply := StampReply.encode {
      forgeId
      mark
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
  s := Grpc.Orca.registerOob s orcaRef
  match ← IO.getEnv "LEAN_GRPC_DEMO_OPS" with
  | some "1" =>
    s := Grpc.Reflection.register s #[
      serviceName,
      "grpc.health.v1.Health",
      "grpc.channelz.v1.Channelz",
      Grpc.Orca.oobService
    ]
    s := Grpc.Channelz.register s counters
  | _ => pure ()

  if useTls then
    let tlsCfg : Grpc.Tls.Config := {
      certPath := some (System.FilePath.mk cert)
      keyPath := some (System.FilePath.mk key)
      clientCaPath := clientCa.map System.FilePath.mk
    }
    let mtlsNote := if mtls then " (mTLS)" else ""
    IO.println s!"MirrorForge[{forgeId}] TLS+ALPN on 127.0.0.1:{port.toNat}{mtlsNote}"
    Grpc.Server.serveTls s tlsCfg { host := "127.0.0.1", port }
  else
    IO.println s!"MirrorForge[{forgeId}] on 127.0.0.1:{port.toNat}"
    Grpc.Server.serveH2c s { host := "127.0.0.1", port }
