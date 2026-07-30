/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto
import Bytes.Slice

def main : IO Unit := do
  let msg := Grpc.Message.encodeId (Proto.HelloRequest.encode { name := "x" })
  match Grpc.Message.decodeOne (Bytes.Slice.ofByteArray msg) with
  | .error e => throw (IO.userError e)
  | .ok (p, rest) =>
    if !rest.isEmpty then throw (IO.userError "rest")
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "x" then throw (IO.userError "name")
  if Grpc.StatusCode.ok.toUInt32 != 0 then throw (IO.userError "status")

  -- gzip message framing round-trip (stored deflate)
  let raw := Proto.HelloRequest.encode { name := "gz" }
  let gzMsg ← IO.ofExcept (Grpc.Message.encode raw .gzip)
  match Grpc.Message.decodeOne (Bytes.Slice.ofByteArray gzMsg) with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "gz" then throw (IO.userError "gzip name")

  -- peer-compatible gzip via system gzip (deflate)
  let peerMsg ← Grpc.Message.encodeIO raw .gzip
  match ← Grpc.Message.decodeOneIO (Bytes.Slice.ofByteArray peerMsg) with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "gz" then throw (IO.userError "peer gzip name")
  -- peer inflate of stored gzip still works
  match ← Grpc.Message.decodeOneIO (Bytes.Slice.ofByteArray gzMsg) with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "gz" then throw (IO.userError "stored via peer path")

  -- percent encode/decode
  let enc := Grpc.Metadata.percentEncode "hello world/x"
  if !enc.contains '%' then throw (IO.userError s!"pct enc {enc}")
  let dec := Grpc.Metadata.percentDecode enc
  if dec != "hello world/x" then throw (IO.userError s!"pct {dec}")

  -- base64 bin metadata
  let bin := ByteArray.mk #[1, 2, 3, 4]
  let b64 := Grpc.Metadata.base64Encode bin
  let back ← IO.ofExcept (Grpc.Metadata.base64Decode b64)
  if back != bin then throw (IO.userError "b64")

  -- timeout parse
  match Grpc.Metadata.parseTimeoutMs "10S" with
  | some 10000 => pure ()
  | _ => throw (IO.userError "timeout S")
  match Grpc.Metadata.parseTimeoutMs "1n" with
  | some 0 => pure ()
  | _ => throw (IO.userError "timeout n")

  -- UTF-8 percent encode (special_status_message)
  let msg := "BMP ☺ emoji 😈"
  let enc := Grpc.Metadata.percentEncode msg
  if !(enc.contains "%E2") then throw (IO.userError s!"pct utf8 {enc}")
  if Grpc.Metadata.percentDecode enc != msg then throw (IO.userError "pct roundtrip")

  -- Resolver / service config / retry
  let addr ← IO.ofExcept (Grpc.Resolver.parseTarget "dns:///127.0.0.1:10000")
  if addr.port != 10000 then throw (IO.userError "resolver port")
  let cfg := Grpc.ServiceConfig.parse "{\"loadBalancingPolicy\":\"round_robin\",\"timeout\":\"1s\"}"
  if cfg.loadBalancingPolicy != "round_robin" then throw (IO.userError "lb policy")
  if cfg.timeoutMs != some 1000 then throw (IO.userError "svc timeout")
  let policy : Grpc.ServiceConfig.RetryPolicy := { maxAttempts := 3, retryableStatusCodes := #[14] }
  if !Grpc.Retry.shouldRetry policy .unavailable 0 then throw (IO.userError "retry")
  if Grpc.Retry.shouldRetry policy .ok 0 then throw (IO.userError "no retry ok")

  -- Credentials compose
  let creds := Grpc.Credentials.CallCredentials.composite
    (Grpc.Credentials.CallCredentials.accessToken "t")
    (Grpc.Credentials.CallCredentials.jwt "j.w.t")
  let md ← creds.apply {}
  if (md.get? "authorization").isNone then throw (IO.userError "creds")

  -- Well-known Any + map
  let anyB := Proto.WellKnown.AnyMsg.encode { typeUrl := "type.googleapis.com/x", value := ByteArray.mk #[1] }
  let any ← IO.ofExcept (Proto.WellKnown.AnyMsg.decode anyB)
  if any.typeUrl != "type.googleapis.com/x" then throw (IO.userError "any")

  -- Proto UTF-8 strings
  let es := Proto.EchoStatus.encode { code := 2, message := "☺" }
  let esd ← IO.ofExcept (Proto.EchoStatus.decode es)
  if esd.message != "☺" then throw (IO.userError "echo utf8")

  -- GCP allowlist non-empty
  if Grpc.Gcp.deferredCases.isEmpty then throw (IO.userError "gcp allowlist")

  -- JWT fixture + ORCA + xDS bootstrap
  let jwt := Grpc.Jwt.fixtureUnsigned "u@example.com"
  if Grpc.Jwt.usernameFromAuthorization s!"Bearer {jwt}" != "u@example.com" then
    throw (IO.userError "jwt claim")
  let orca : Grpc.Orca.Report := { cpuUtilizationMillis := 1, memoryUtilizationMillis := 2 }
  let orca2 ← IO.ofExcept (Grpc.Orca.Report.decode (Grpc.Orca.Report.encode orca))
  if orca2 != orca then throw (IO.userError "orca roundtrip")
  let boot := Grpc.Xds.parseBootstrap "{\"clusters\":{\"c\":[\"127.0.0.1:9\"]}}"
  let xs ← IO.ofExcept (Grpc.Xds.resolve boot "xds:///c")
  if xs.size != 1 then throw (IO.userError "xds resolve")
  let hedge := Grpc.ServiceConfig.parse "{\"hedgingPolicy\":{}}"
  if hedge.hedging.isNone then throw (IO.userError "hedge parse")

  IO.println "grpcTests OK"
