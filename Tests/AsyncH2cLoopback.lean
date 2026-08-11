/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import H2
import Proto
import Std.Async
import Std.Async.Timer

open Std.Async

/-- Concurrent Async h2c loopback: `serveH2cAsync` + multiple `connectH2cAsync` /
    `unaryCallAsync` clients on one UV loop (no `.block` on the Async hot path). -/
private def oneClient (port : UInt16) (name : String) : Async String := do
  let c ← H2.Client.connectH2cAsync "127.0.0.1" port
  let req := Proto.HelloRequest.encode { name }
  let res ← Grpc.Client.unaryCallAsync c "helloworld.Greeter" "SayHello" "127.0.0.1" req
  if res.status.code != .ok then
    throw (IO.userError s!"status {res.status.code.toUInt32}")
  let reply ← liftM (IO.ofExcept (Proto.HelloReply.decode res.message))
  return reply.message

def main : IO Unit := do
  let port : UInt16 := 50061
  let mut s := Grpc.Server.empty
  s := Grpc.Server.register s "helloworld.Greeter" "SayHello" fun reqBytes => do
    let req ← IO.ofExcept (Proto.HelloRequest.decode reqBytes)
    let reply : Proto.HelloReply := { message := s!"Hello, {req.name}" }
    return (Proto.HelloReply.encode reply, Grpc.Status.ok)
  (do
    background (prio := Task.Priority.dedicated) do
      Grpc.Server.serveH2cAsync s { host := "127.0.0.1", port }
    sleep (Std.Time.Millisecond.Offset.ofNat 400)
    let names : Array String := #["A", "B", "C", "D", "E", "F", "G", "H"]
    let msgs : Array String ← Async.concurrentlyAll (names.map fun n => oneClient port n)
    if msgs.size != names.size then
      throw (IO.userError s!"expected {names.size} replies, got {msgs.size}")
    for msg in msgs do
      if !("Hello".isPrefixOf msg) then
        throw (IO.userError msg)
    IO.println "asyncH2cLoopback OK"
  ).block
