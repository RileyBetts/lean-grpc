/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

def main : IO Unit := do
  let counters ← IO.mkRef ({} : Grpc.Channelz.Counters)
  let healthStatus ← IO.mkRef Grpc.Health.ServingStatus.serving
  let mut s := Grpc.Server.empty
  s := Grpc.Server.register s "helloworld.Greeter" "SayHello" fun reqBytes => do
    let req ← IO.ofExcept (Proto.HelloRequest.decode reqBytes)
    let reply : Proto.HelloReply := { message := s!"Hello, {req.name}" }
    Grpc.Channelz.recordSuccess counters
    return (Proto.HelloReply.encode reply, Grpc.Status.ok)
  -- Ops surfaces (reflection/channelz) require LEAN_GRPC_DEMO_OPS=1 (CI sets this for opsSmoke).
  match ← IO.getEnv "LEAN_GRPC_DEMO_OPS" with
  | some "1" =>
    s := Grpc.Health.registerWithWatch s healthStatus
    s := Grpc.Reflection.register s #["helloworld.Greeter", "grpc.health.v1.Health", "grpc.channelz.v1.Channelz"]
    s := Grpc.Channelz.register s counters
  | _ =>
    s := Grpc.Health.registerWithWatch s healthStatus
  Grpc.Server.serveH2c s { host := "127.0.0.1", port := 50051 }
