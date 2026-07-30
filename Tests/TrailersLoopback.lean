/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Lean↔Lean unary verifying trailers arrive separately from headers.
    Spawns `trailersServer` in a child process (Std.Async TCP cannot share one UV loop
    across IO.asTask workers that each call `.block`). -/
def main : IO Unit := do
  let port : UInt16 := 50059
  let binDir := (← IO.appDir)
  let serverPath := binDir / "trailersServer"
  let child ← IO.Process.spawn {
    cmd := serverPath.toString
    env := #[("GRPC_PORT", some (toString port.toNat))]
  }
  try
    IO.sleep 400
    let ch ← Grpc.Channel.connectH2c "127.0.0.1" port
    let res ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello"
      (Proto.HelloRequest.encode { name := "Trailers" })
    if res.status.code != .ok then
      throw (IO.userError s!"status {res.status.code.toUInt32}")
    if res.trailers.isEmpty then
      throw (IO.userError "expected trailers HEADERS frame")
    let mut sawStatus := false
    for h in res.trailers do
      let n := String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat))
      if n == "grpc-status" then sawStatus := true
    if !sawStatus then throw (IO.userError "grpc-status not in trailers")
    for h in res.headers do
      let n := String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat))
      if n == "grpc-status" then throw (IO.userError "grpc-status should not be in headers")
    let reply ← IO.ofExcept (Proto.HelloReply.decode res.message)
    if !("Hello".isPrefixOf reply.message) then
      throw (IO.userError reply.message)
    IO.println "trailersLoopback OK"
  finally
    child.kill
