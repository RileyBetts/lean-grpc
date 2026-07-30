/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Minimal gRPC interop server: empty_unary + large_unary (identity). -/
def main : IO Unit := do
  let mut s := Grpc.Server.empty
  s := Grpc.Server.register s "grpc.testing.TestService" "EmptyCall" fun _ => do
    return (ByteArray.empty, Grpc.Status.ok)
  s := Grpc.Server.register s "grpc.testing.TestService" "UnaryCall" fun reqBytes => do
    let req ← IO.ofExcept (Proto.SimpleRequest.decode reqBytes)
    let body := Id.run do
      let mut b := ByteArray.empty
      for _ in [:req.responseSize.toNat] do
        b := b.push 0
      return b
    let resp := Proto.SimpleResponse.encode { payloadBody := body, username := if req.fillUsername then "lean" else "" }
    return (resp, Grpc.Status.ok)
  let port := ((← IO.getEnv "GRPC_PORT").getD "10000").toNat?.getD 10000 |>.toUInt16
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
