/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "10000").toNat?.getD 10000 |>.toUInt16
  let case_ := args[2]?.getD "empty_unary"
  let ch ← Grpc.Channel.connectH2c host port
  match case_ with
  | "empty_unary" =>
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "EmptyCall" ByteArray.empty
    if res.status.code != .ok then throw (IO.userError "empty_unary failed")
    IO.println "empty_unary OK"
  | "large_unary" =>
    let req := Proto.SimpleRequest.encode { responseSize := 314159 }
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" req
    if res.status.code != .ok then throw (IO.userError "large_unary failed")
    let resp ← IO.ofExcept (Proto.SimpleResponse.decode res.message)
    if resp.payloadBody.size != 314159 then throw (IO.userError "size")
    IO.println "large_unary OK"
  | other => throw (IO.userError s!"unknown case {other}")
