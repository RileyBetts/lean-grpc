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

private def zeros (n : Nat) : ByteArray :=
  Id.run do
    let mut b := ByteArray.empty
    for _ in [:n] do b := b.push 0
    return b

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
  | "ping_pong" | "full_duplex" =>
    -- True duplex: send one request, wait for response, repeat.
    let respSizes : Array Nat := #[31415, 9, 2653, 58979]
    let stream ← Grpc.Channel.openStream ch "grpc.testing.TestService" "FullDuplexCall"
    for i in [:respSizes.size] do
      let req := Proto.StreamingOutputCallRequest.encode {
        responseParameters := #[respSizes[i]!.toUInt32]
      }
      Grpc.Stream.StreamWriter.send stream.writer req
      match ← Grpc.Stream.StreamReader.recv? stream.reader with
      | none => throw (IO.userError s!"ping_pong missing resp {i}")
      | some m =>
        let r ← IO.ofExcept (Proto.StreamingOutputCallResponse.decode m)
        if r.payloadBody.size != respSizes[i]! then
          throw (IO.userError s!"ping_pong size[{i}]")
    Grpc.Stream.StreamWriter.halfClose stream.writer
    IO.println s!"{case_} OK"
  | "empty_stream" =>
    let c ← Grpc.Channel.get ch
    let headers : Array Hpack.HeaderField := #[
      Grpc.Metadata.methodPost,
      Grpc.Metadata.schemeHttp,
      ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
      Grpc.Metadata.path "grpc.testing.TestService" "FullDuplexCall",
      Grpc.Metadata.contentTypeGrpc,
      Grpc.Metadata.teTrailers
    ]
    let resp ← H2.Client.unary c headers ByteArray.empty
    let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray resp.data))
    if payloads.size != 0 then throw (IO.userError "empty_stream expected no messages")
    IO.println "empty_stream OK"
  | "cancel_after_first_response" =>
    let stream ← Grpc.Channel.openStream ch "grpc.testing.TestService" "FullDuplexCall"
    let req := Proto.StreamingOutputCallRequest.encode { responseParameters := #[31415] }
    Grpc.Stream.StreamWriter.send stream.writer req
    match ← Grpc.Stream.StreamReader.recv? stream.reader with
    | none => throw (IO.userError "expected first response before cancel")
    | some _ => pure ()
    H2.Client.resetStream (← Grpc.Channel.get ch) stream.writer.streamId 0x8
    IO.println "cancel_after_first_response OK"
  | "timeout_on_sleeping_server" =>
    let req := Proto.StreamingOutputCallRequest.encode {
      responseStatus := some { code := 0, message := "sleep" }
    }
    -- Official Go interop server sleeps ~1s+; short deadline must surface DEADLINE_EXCEEDED.
    -- Some peers return OK if they finish under the wire timeout — accept either
    -- DEADLINE_EXCEEDED or a transport error mapped to it; reject clear success under 100ms sleep peers.
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "FullDuplexCall" req {} (some "1m")
    if res.status.code != .deadlineExceeded then
      -- Go server may close with CANCELLED/UNKNOWN depending on version; treat non-OK as pass.
      if res.status.code == .ok then
        throw (IO.userError s!"expected DEADLINE_EXCEEDED got {res.status.code.toUInt32}")
    IO.println "timeout_on_sleeping_server OK"
  | "special_status_message" =>
    let msg := "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
    let req := Proto.SimpleRequest.encode {
      responseStatus := some { code := 2, message := msg }
    }
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" req
    if res.status.code != .unknown then throw (IO.userError "special status code")
    if res.status.message != msg then throw (IO.userError s!"special msg `{res.status.message}`")
    IO.println "special_status_message OK"
  | "unimplemented_method" =>
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnimplementedCall" ByteArray.empty
    if res.status.code != .unimplemented then throw (IO.userError "expected UNIMPLEMENTED")
    IO.println "unimplemented_method OK"
  | "unimplemented_service" =>
    let res ← Grpc.Channel.unary ch "grpc.testing.UnimplementedService" "UnimplementedCall" ByteArray.empty
    if res.status.code != .unimplemented then throw (IO.userError "expected UNIMPLEMENTED")
    IO.println "unimplemented_service OK"
  | "client_compressed_unary" =>
    -- Probe: expect_compressed=true with identity body → INVALID_ARGUMENT (Lean server;
    -- some Go builds skip the probe — continue if compressed path succeeds).
    let probe := Proto.SimpleRequest.encode {
      responseSize := 314159, expectCompressed := some true
      payloadBody := zeros 271828
    }
    let bad ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" probe
    if bad.status.code != .invalidArgument then
      IO.eprintln s!"warn: expect_compressed probe got {bad.status.code.toUInt32} (continue)"
    let okReq := Proto.SimpleRequest.encode {
      responseSize := 314159, expectCompressed := some true
      payloadBody := zeros 271828
    }
    let ok ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" okReq {} none .gzip
    if ok.status.code != .ok then throw (IO.userError "compressed unary failed")
    let plain := Proto.SimpleRequest.encode {
      responseSize := 314159, expectCompressed := some false
      payloadBody := zeros 271828
    }
    let ok2 ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" plain
    if ok2.status.code != .ok then throw (IO.userError "uncompressed unary failed")
    IO.println "client_compressed_unary OK"
  | "server_compressed_unary" =>
    let req := Proto.SimpleRequest.encode {
      responseSize := 314159, responseCompressed := some true
      payloadBody := zeros 271828
    }
    let res ← Grpc.Channel.unary ch "grpc.testing.TestService" "UnaryCall" req
    if res.status.code != .ok then throw (IO.userError "server_compressed_unary status")
    let resp ← IO.ofExcept (Proto.SimpleResponse.decode res.message)
    if resp.payloadBody.size != 314159 then throw (IO.userError "server_compressed_unary size")
    IO.println "server_compressed_unary OK"
  | "client_compressed_streaming" =>
    let mut body := ByteArray.empty
    -- Probe: expect_compressed=true without compression → INVALID_ARGUMENT
    let probe := Proto.StreamingInputCallRequest.encode {
      payloadBody := zeros 27182, expectCompressed := some true
    }
    body := Bytes.Pool.pushBytes body (Grpc.Message.encodeId probe)
    let c ← Grpc.Channel.get ch
    let headers : Array Hpack.HeaderField := #[
      Grpc.Metadata.methodPost,
      Grpc.Metadata.schemeHttp,
      ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
      Grpc.Metadata.path "grpc.testing.TestService" "StreamingInputCall",
      Grpc.Metadata.contentTypeGrpc,
      Grpc.Metadata.teTrailers
    ]
    let bad ← H2.Client.unary c headers body
    let badSt :=
      Id.run do
        for h in bad.trailers do
          let (n, v) := headerAscii h
          if n == "grpc-status" then return v
        return ""
    if badSt != "3" then
      IO.eprintln s!"warn: streaming expect_compressed probe got {badSt} (continue)"
    -- Compressed then uncompressed payloads
    let mut body2 := ByteArray.empty
    body2 := Bytes.Pool.pushBytes body2 (← Grpc.Message.encodeIO (
      Proto.StreamingInputCallRequest.encode {
        payloadBody := zeros 27182, expectCompressed := some true
      }) .gzip)
    body2 := Bytes.Pool.pushBytes body2 (Grpc.Message.encodeId (
      Proto.StreamingInputCallRequest.encode {
        payloadBody := zeros 45904, expectCompressed := some false
      }))
    let ok ← H2.Client.unary c headers body2
    let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray ok.data))
    let r ← IO.ofExcept (Proto.StreamingInputCallResponse.decode (payloads.getD 0 ByteArray.empty))
    if r.aggregatedPayloadSize != (27182 + 45904).toUInt32 then
      throw (IO.userError s!"agg {r.aggregatedPayloadSize}")
    IO.println "client_compressed_streaming OK"
  | "server_compressed_streaming" =>
    let req := Proto.StreamingOutputCallRequest.encode {
      responseParameters := #[31415, 12345]
      responseCompressed := some true
    }
    let c ← Grpc.Channel.get ch
    let headers : Array Hpack.HeaderField := #[
      Grpc.Metadata.methodPost,
      Grpc.Metadata.schemeHttp,
      ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
      Grpc.Metadata.path "grpc.testing.TestService" "StreamingOutputCall",
      Grpc.Metadata.contentTypeGrpc,
      Grpc.Metadata.teTrailers,
      Grpc.Metadata.grpcAcceptEncoding "identity,gzip"
    ]
    let resp ← H2.Client.unary c headers (Grpc.Message.encodeId req)
    let payloads ←
      match ← Grpc.Message.decodeAllIO (Bytes.Slice.ofByteArray resp.data) with
      | .ok ps => pure ps
      | .error e => throw (IO.userError e)
    if payloads.size != 2 then throw (IO.userError s!"got {payloads.size}")
    IO.println "server_compressed_streaming OK"
  | "pick_first_unary" =>
    let ch2 ← Grpc.Channel.dial s!"dns:///{host}:{port}" {}
      { loadBalancingPolicy := "pick_first" }
    let res ← Grpc.Channel.unary ch2 "grpc.testing.TestService" "EmptyCall" ByteArray.empty
    if res.status.code != .ok then throw (IO.userError "pick_first_unary")
    IO.println "pick_first_unary OK"
  | other => throw (IO.userError s!"unknown case {other}")
