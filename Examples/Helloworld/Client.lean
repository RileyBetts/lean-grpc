/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50051").toNat?.getD 50051 |>.toUInt16
  let name := args[2]?.getD "Lean"
  let ch ← Grpc.Channel.connectH2c host port
  let req := Proto.HelloRequest.encode { name }
  let res ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello" req
  if res.status.code != .ok then
    IO.eprintln s!"rpc failed: {res.status.code.toUInt32} {res.status.message}"
    return
  let reply ← IO.ofExcept (Proto.HelloReply.decode res.message)
  IO.println reply.message
