/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import H2
import Examples.Helloworld.Generated

/-- Typed helloworld server (stubs from `Generated.lean` / `./scripts/gen-helloworld.sh`). -/
def main : IO Unit := do
  let counters ← IO.mkRef ({} : Grpc.Channelz.Counters)
  let healthStatus ← IO.mkRef Grpc.Health.ServingStatus.serving
  let mut s := Grpc.Server.empty
  s := helloworld.registerGreeterSayHello s fun req => do
    let reply : helloworld.HelloReply := { message := s!"Hello, {req.name}" }
    Grpc.Channelz.recordSuccess counters
    return (reply, Grpc.Status.ok)
  -- Ops surfaces (reflection/channelz) require LEAN_GRPC_DEMO_OPS=1 (CI sets this for opsSmoke).
  match ← IO.getEnv "LEAN_GRPC_DEMO_OPS" with
  | some "1" =>
    s := Grpc.Health.registerWithWatch s healthStatus
    s := Grpc.Reflection.register s #["helloworld.Greeter", "grpc.health.v1.Health", "grpc.channelz.v1.Channelz"]
    s := Grpc.Channelz.register s counters
  | _ =>
    s := Grpc.Health.registerWithWatch s healthStatus
  let cfg : H2.ServerConfig := { host := "127.0.0.1", port := 50051 }
  match ← IO.getEnv "LEAN_GRPC_ASYNC" with
  | some "1" => (Grpc.Server.serveH2cAsync s cfg).block
  | _ => Grpc.Server.serveH2c s cfg
