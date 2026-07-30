/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Smoke health / reflection / channelz against a local helloworld-style server. -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  let ch ← Grpc.Channel.connectH2c host port

  let health ← Grpc.Channel.unary ch "grpc.health.v1.Health" "Check" ByteArray.empty
  if health.status.code != .ok then throw (IO.userError "health")
  if health.message.isEmpty then throw (IO.userError "health body")

  let refl ← Grpc.Channel.unary ch "grpc.reflection.v1alpha.ServerReflection"
    "ServerReflectionInfo" ByteArray.empty
  if refl.status.code != .ok then throw (IO.userError "reflection")

  let cz ← Grpc.Channel.unary ch "grpc.channelz.v1.Channelz" "GetTopChannels" ByteArray.empty
  if cz.status.code != .ok then throw (IO.userError "channelz")

  IO.println "opsSmoke OK"
