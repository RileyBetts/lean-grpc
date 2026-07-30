/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto
import Bytes.Slice

def main : IO Unit := do
  let msg := Grpc.Message.encode (Proto.HelloRequest.encode { name := "x" })
  match Grpc.Message.decodeOne (Bytes.Slice.ofByteArray msg) with
  | .error e => throw (IO.userError e)
  | .ok (p, rest) =>
    if !rest.isEmpty then throw (IO.userError "rest")
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "x" then throw (IO.userError "name")
  if Grpc.StatusCode.ok.toUInt32 != 0 then throw (IO.userError "status")
  IO.println "grpcTests OK"
