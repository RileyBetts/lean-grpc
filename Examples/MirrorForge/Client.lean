/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Examples.MirrorForge.Protocol

open Examples.MirrorForge.Protocol

private structure Check where
  name : String
  ok : Bool
  detail : String := ""
  deriving Inhabited

private def pass (name : String) (detail : String := "") : Check := { name, ok := true, detail }
private def fail (name : String) (detail : String) : Check := { name, ok := false, detail }

private def expectOk (name : String) (st : Grpc.StatusCode) : Check :=
  if st == .ok then pass name else fail name s!"status={st.toUInt32}"

private def containsService (services : Array String) (name : String) : Bool :=
  Id.run do
    for s in services do
      if s == name then return true
    return false

def main (args : List String) : IO UInt32 := do
  let host := args[0]?.getD "127.0.0.1"
  let portA := (args[1]?.getD "50201").toNat?.getD 50201 |>.toUInt16
  let _portB := (args[2]?.getD "50202").toNat?.getD 50202 |>.toUInt16
  -- Dual backends come from LEAN_GRPC_RESOLVE_ADDRS (set by run script).
  let mut checks : Array Check := #[]

  let rrCfg := Grpc.ServiceConfig.parse "{\"loadBalancingPolicy\":\"round_robin\"}"
  let retryCfg := Grpc.ServiceConfig.parse
    "{\"retryPolicy\":{\"maxAttempts\":4,\"retryableStatusCodes\":[\"UNAVAILABLE\"],\"initialBackoff\":\"1ms\",\"maxBackoff\":\"5ms\"}}"
  let hedgeCfg := Grpc.ServiceConfig.parse
    "{\"hedgingPolicy\":{\"maxAttempts\":2,\"hedgingDelay\":\"20ms\",\"nonFatalStatusCodes\":[\"UNAVAILABLE\"]}}"
  checks := checks.push (
    if hedgeCfg.hedging.isSome then pass "act.hedge_config" "parsed"
    else fail "act.hedge_config" "missing hedgingPolicy")

  IO.println "mirrorForge: dialing…"
  let chRR ← Grpc.Channel.dial s!"dns:///{host}:{portA.toNat}" {} rrCfg
  let chRetry ← Grpc.Channel.dial s!"{host}:{portA.toNat}" {} retryCfg
  IO.println "mirrorForge: dialed"

  -- Act I: interceptor-wrapped Stamp
  let clientLog ← IO.mkRef (#[] : Array String)
  let stampReq := StampRequest.encode { token := accessToken, billet := "ingot-1" }
  IO.println "mirrorForge: stamp_1…"
  let stamp1 ← Grpc.Interceptor.callUnary chRR serviceName "Stamp"
    #[Grpc.Interceptor.loggingClient clientLog] stampReq
  IO.println s!"mirrorForge: stamp_1 status={stamp1.status.code.toUInt32}"
  checks := checks.push (expectOk "act.stamp_1" stamp1.status.code)
  let reply1 ← IO.ofExcept (StampReply.decode stamp1.message)
  checks := checks.push (
    if !reply1.forgeId.isEmpty && reply1.mark.endsWith "ingot-1" then
      pass "act.stamp_1.mark" reply1.mark
    else fail "act.stamp_1.mark" reply1.mark)
  let clog ← clientLog.get
  checks := checks.push (
    if clog.size == 2 && clog[0]!.startsWith ">" && clog[1]!.startsWith "<" then
      pass "act.client_interceptor" s!"lines={clog.size}"
    else fail "act.client_interceptor" s!"{clog}")

  -- Act II: round-robin across two forges
  let stamp2 ← Grpc.Channel.unary chRR serviceName "Stamp"
    (StampRequest.encode { token := accessToken, billet := "ingot-2" })
  checks := checks.push (expectOk "act.stamp_2" stamp2.status.code)
  let reply2 ← IO.ofExcept (StampReply.decode stamp2.message)
  checks := checks.push (
    if reply1.forgeId != reply2.forgeId then
      pass "act.round_robin" s!"{reply1.forgeId}→{reply2.forgeId}"
    else
      fail "act.round_robin" s!"both hit {reply1.forgeId} (is the second forge up?)")

  -- Act III: bad token → UNAUTHENTICATED
  let bad ← Grpc.Channel.unary chRR serviceName "Stamp"
    (StampRequest.encode { token := "nope", billet := "x" })
  checks := checks.push (
    if bad.status.code == .unauthenticated then pass "act.auth_reject" bad.status.message
    else fail "act.auth_reject" s!"status={bad.status.code.toUInt32}")

  -- Act IV: Quench with retry (first UNAVAILABLE on this forge, then OK)
  let quench ← Grpc.Channel.unary chRetry serviceName "Quench" ByteArray.empty
  checks := checks.push (expectOk "act.retry_quench" quench.status.code)

  -- Act V: Health Check + Watch
  let health ← Grpc.Channel.unary chRR "grpc.health.v1.Health" "Check" ByteArray.empty
  checks := checks.push (expectOk "act.health_check" health.status.code)
  let watch ← Grpc.Channel.unary chRR "grpc.health.v1.Health" "Watch" ByteArray.empty
  checks := checks.push (
    if watch.status.code == .ok && !watch.message.isEmpty then pass "act.health_watch" "snapshot"
    else fail "act.health_watch" s!"status={watch.status.code.toUInt32}")

  -- Act VI: Reflection
  let reflReq := Grpc.Reflection.listServicesRequest
  let refl ← Grpc.Channel.unary chRR "grpc.reflection.v1alpha.ServerReflection"
    "ServerReflectionInfo" reflReq
  checks := checks.push (expectOk "act.reflection_v1alpha" refl.status.code)
  let reflResp ← IO.ofExcept (Grpc.Reflection.Response.decode refl.message)
  let services := reflResp.services.getD #[]
  checks := checks.push (
    if containsService services serviceName && containsService services "grpc.health.v1.Health" then
      pass "act.reflection_services" s!"n={services.size}"
    else fail "act.reflection_services" s!"{services}")
  let reflV1 ← Grpc.Channel.unary chRR "grpc.reflection.v1.ServerReflection"
    "ServerReflectionInfo" reflReq
  checks := checks.push (expectOk "act.reflection_v1" reflV1.status.code)

  -- Act VII: Channelz
  let cz ← Grpc.Channel.unary chRR "grpc.channelz.v1.Channelz" "GetTopChannels" ByteArray.empty
  checks := checks.push (expectOk "act.channelz" cz.status.code)
  let czc ← IO.ofExcept (Grpc.Channelz.decodeGetTopChannelsCounters cz.message)
  checks := checks.push (
    if czc.callsStarted > 0 then pass "act.channelz.calls" s!"started={czc.callsStarted}"
    else fail "act.channelz.calls" "zero")

  -- Act VIII: Binary log
  let sink ← Grpc.BinaryLog.newSink
  let logged ← Grpc.BinaryLog.logUnaryCall sink 7 chRR serviceName "Stamp"
    (StampRequest.encode { token := accessToken, billet := "logged" })
  checks := checks.push (expectOk "act.binlog.call" logged.status.code)
  let ev ← Grpc.BinaryLog.events sink
  checks := checks.push (
    if ev.size == 5 then pass "act.binlog.events" "5"
    else fail "act.binlog.events" s!"got {ev.size}")

  -- Act IX: Stats
  let stats ← Grpc.Stats.newRegistry
  Grpc.Stats.recordStart stats
  Grpc.Stats.recordSuccess stats logged.message.size 0
  let snap ← Grpc.Stats.snapshot stats
  checks := checks.push (
    if snap.callsStarted == 1 && snap.callsCompleted == 1 then pass "act.stats" "ok"
    else fail "act.stats" s!"{snap.callsStarted}/{snap.callsCompleted}")

  -- Act X: ORCA OOB + load in Stamp reply
  let oob ← Grpc.Orca.fetchOob chRR
  checks := checks.push (
    if oob.cpuUtilization > 0.0 then pass "act.orca_oob" s!"cpu={oob.cpuUtilization}"
    else fail "act.orca_oob" "cpu=0")
  checks := checks.push (
    if reply1.cpuLoad > 0.0 then pass "act.orca_in_reply" s!"cpu={reply1.cpuLoad}"
    else fail "act.orca_in_reply" "missing")

  -- Act XI: SlowStamp (plain unary; hedging races use background tasks that can
  -- keep the process alive, so we only assert the config parse + a slow RPC OK).
  let slow ← Grpc.Channel.unary chRetry serviceName "SlowStamp"
    (StampRequest.encode { token := accessToken, billet := "anneal" })
  checks := checks.push (expectOk "act.slow_stamp" slow.status.code)

  let mut failed : Nat := 0
  IO.println "======== MirrorForge (Lean↔Lean) results ========"
  for c in checks do
    let mark := if c.ok then "PASS" else "FAIL"
    if !c.ok then failed := failed + 1
    if c.detail.isEmpty then IO.println s!"{mark}  {c.name}"
    else IO.println s!"{mark}  {c.name}  ({c.detail})"
  IO.println "================================================="
  if failed == 0 then
    IO.println s!"VERDICT: ALL {checks.size} CHECKS PASSED — Lean↔Lean ops/LB/retry surfaces OK."
    return 0
  else
    IO.println s!"VERDICT: {failed}/{checks.size} FAILED."
    return 1
