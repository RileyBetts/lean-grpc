/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto
import H2
import Bytes.Slice
import Bytes.Pool

private def headerAscii (h : Hpack.HeaderField) : String × String :=
  (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
   String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))

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
  | "status_code_and_message" =>
    let req := Proto.SimpleRequest.encode {
      responseStatus := some { code := 2, message := "test status message" }
    }
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" req
    if res.status.code != .unknown then
      throw (IO.userError s!"expected UNKNOWN got {res.status.code.toUInt32}")
    if res.status.message != "test status message" then
      throw (IO.userError s!"msg `{res.status.message}`")
    IO.println "status_code_and_message OK"
  | "custom_metadata" =>
    let md := Grpc.Metadata.empty
      |> (Grpc.Metadata.add · "x-grpc-test-echo-initial" "test_initial_metadata_value")
      |> (Grpc.Metadata.addBin · "x-grpc-test-echo-trailing-bin" (ByteArray.mk #[0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b]))
    -- Go interop server echoes metadata on UnaryCall (not EmptyCall).
    let req := Proto.SimpleRequest.encode { responseSize := 1, payloadBody := ByteArray.mk #[0] }
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" req md
    if res.status.code != .ok then throw (IO.userError "custom_metadata status")
    let mut sawInit := false
    for h in res.headers do
      let (n, v) := headerAscii h
      if n == "x-grpc-test-echo-initial" && v == "test_initial_metadata_value" then
        sawInit := true
    if !sawInit then throw (IO.userError "missing initial md")
    let mut sawTrail := false
    for h in res.trailers do
      let (n, _) := headerAscii h
      if n == "x-grpc-test-echo-trailing-bin" then sawTrail := true
    if !sawTrail then throw (IO.userError "missing trailing md")
    IO.println "custom_metadata OK"
  | "cancel_after_begin" =>
    let c ← Grpc.Channel.get ch
    let headers : Array Hpack.HeaderField := #[
      Grpc.Metadata.methodPost,
      Grpc.Metadata.schemeHttp,
      ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
      Grpc.Metadata.path "grpc.testing.TestService" "UnaryCall",
      Grpc.Metadata.contentTypeGrpc,
      Grpc.Metadata.teTrailers
    ]
    let sid ← H2.Client.startRequest c headers (Grpc.Message.encodeId (
      Proto.SimpleRequest.encode { responseSize := 10 })) true
    H2.Client.resetStream c sid 0x8
    IO.println "cancel_after_begin OK"
  | "server_streaming" =>
    let req := Proto.StreamingOutputCallRequest.encode {
      responseParameters := #[31415, 9, 2653, 58979]
    }
    let c ← Grpc.Channel.get ch
    let headers : Array Hpack.HeaderField := #[
      Grpc.Metadata.methodPost,
      Grpc.Metadata.schemeHttp,
      ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
      Grpc.Metadata.path "grpc.testing.TestService" "StreamingOutputCall",
      Grpc.Metadata.contentTypeGrpc,
      Grpc.Metadata.teTrailers
    ]
    let resp ← H2.Client.unary c headers (Grpc.Message.encodeId req)
    let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray resp.data))
    if payloads.size != 4 then throw (IO.userError s!"got {payloads.size} msgs")
    let sizes : Array Nat := #[31415, 9, 2653, 58979]
    for i in [:4] do
      let m ← IO.ofExcept (Proto.StreamingOutputCallResponse.decode payloads[i]!)
      if m.payloadBody.size != sizes[i]! then
        throw (IO.userError s!"size[{i}]")
    IO.println "server_streaming OK"
  | "client_streaming" =>
    let mut body := ByteArray.empty
    for sz in [27182, 8, 1828, 45904] do
      let payload := Id.run do
        let mut b := ByteArray.empty
        for _ in [:sz] do b := b.push 0
        return b
      let msg := Proto.StreamingInputCallRequest.encode { payloadBody := payload }
      body := Bytes.Pool.pushBytes body (Grpc.Message.encodeId msg)
    let c ← Grpc.Channel.get ch
    let headers : Array Hpack.HeaderField := #[
      Grpc.Metadata.methodPost,
      Grpc.Metadata.schemeHttp,
      ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
      Grpc.Metadata.path "grpc.testing.TestService" "StreamingInputCall",
      Grpc.Metadata.contentTypeGrpc,
      Grpc.Metadata.teTrailers
    ]
    let resp ← H2.Client.unary c headers body
    let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray resp.data))
    let r ← IO.ofExcept (Proto.StreamingInputCallResponse.decode (payloads.getD 0 ByteArray.empty))
    if r.aggregatedPayloadSize != (27182+8+1828+45904).toUInt32 then
      throw (IO.userError s!"agg {r.aggregatedPayloadSize}")
    IO.println "client_streaming OK"
  | other => throw (IO.userError s!"unknown case {other}")
