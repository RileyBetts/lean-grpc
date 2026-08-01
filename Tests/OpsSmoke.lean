/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Smoke health/watch/reflection/channelz/binary-log/stats against a local
    helloworld-style server. -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  let ch ← Grpc.Channel.connectH2c host port

  -- Health: Check.
  let health ← Grpc.Channel.unary ch "grpc.health.v1.Health" "Check" ByteArray.empty
  if health.status.code != .ok then throw (IO.userError "health")
  if health.message.isEmpty then throw (IO.userError "health body")

  -- Health: Watch (server-streaming; this server answers with a single current snapshot).
  let watch ← Grpc.Channel.unary ch "grpc.health.v1.Health" "Watch" ByteArray.empty
  if watch.status.code != .ok then throw (IO.userError "health watch")
  if watch.message.isEmpty then throw (IO.userError "health watch body")

  -- Reflection: real list_services request/response round trip.
  let reflReq := Grpc.Reflection.listServicesRequest
  let refl ← Grpc.Channel.unary ch "grpc.reflection.v1alpha.ServerReflection"
    "ServerReflectionInfo" reflReq
  if refl.status.code != .ok then throw (IO.userError "reflection")
  let reflResp ← IO.ofExcept (Grpc.Reflection.Response.decode refl.message)
  let services := reflResp.services.getD #[]
  if !(services.contains "grpc.health.v1.Health") then
    throw (IO.userError s!"reflection: missing Health in {services}")

  -- Reflection v1 (same registry, distinct service name).
  let reflV1 ← Grpc.Channel.unary ch "grpc.reflection.v1.ServerReflection"
    "ServerReflectionInfo" reflReq
  if reflV1.status.code != .ok then throw (IO.userError "reflection v1")

  -- Drive at least one counted RPC so channelz counters below are non-zero.
  let hello ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello"
    (Proto.HelloRequest.encode { name := "opsSmoke" })
  if hello.status.code != .ok then throw (IO.userError "hello")

  -- Channelz: GetTopChannels + GetServers with real counters (at least the calls above).
  let cz ← Grpc.Channel.unary ch "grpc.channelz.v1.Channelz" "GetTopChannels" ByteArray.empty
  if cz.status.code != .ok then throw (IO.userError "channelz channels")
  let czCounters ← IO.ofExcept (Grpc.Channelz.decodeGetTopChannelsCounters cz.message)
  if czCounters.callsStarted == 0 then throw (IO.userError "channelz: no calls recorded")

  let czSrv ← Grpc.Channel.unary ch "grpc.channelz.v1.Channelz" "GetServers" ByteArray.empty
  if czSrv.status.code != .ok then throw (IO.userError "channelz servers")
  discard <| IO.ofExcept (Grpc.Channelz.decodeGetServersCounters czSrv.message)

  -- Binary log: wrap one more health check and confirm the full event sequence was captured.
  let sink ← Grpc.BinaryLog.newSink
  let logged ← Grpc.BinaryLog.logUnaryCall sink 1 ch "grpc.health.v1.Health" "Check" ByteArray.empty
  if logged.status.code != .ok then throw (IO.userError "binlog call")
  let events ← Grpc.BinaryLog.events sink
  if events.size != 5 then throw (IO.userError s!"binlog: expected 5 events, got {events.size}")
  if (← Grpc.BinaryLog.countOf sink .clientMessage) != 1 then
    throw (IO.userError "binlog: missing client message event")
  if (← Grpc.BinaryLog.countOf sink .serverTrailer) != 1 then
    throw (IO.userError "binlog: missing server trailer event")

  -- Stats: minimal counters + stdout/OTel-stub exporter.
  let stats ← Grpc.Stats.newRegistry
  Grpc.Stats.recordStart stats
  Grpc.Stats.recordSuccess stats health.message.size 0
  let snap ← Grpc.Stats.snapshot stats
  if snap.callsStarted != 1 || snap.callsCompleted != 1 then
    throw (IO.userError "stats: counters not recorded")
  let lines := Grpc.Stats.toLines snap
  if !(lines.any (·.startsWith "grpc_calls_started_total")) then
    throw (IO.userError "stats: missing exposition line")
  Grpc.Stats.OtelExporter.export Grpc.Stats.OtelExporter.stdout stats

  -- Interceptor chain: client-side logging interceptor around a real unary call.
  let icptSink ← IO.mkRef (#[] : Array String)
  let icptRes ← Grpc.Interceptor.callUnary ch "grpc.health.v1.Health" "Check"
    #[Grpc.Interceptor.loggingClient icptSink] ByteArray.empty
  if icptRes.status.code != .ok then throw (IO.userError "interceptor call")
  let icptLog ← icptSink.get
  if icptLog.size != 2 then throw (IO.userError s!"interceptor: expected 2 log lines, got {icptLog.size}")
  if !(icptLog[0]!.startsWith ">") || !(icptLog[1]!.startsWith "<") then
    throw (IO.userError s!"interceptor: unexpected log shape {icptLog}")

  IO.println "opsSmoke OK"
