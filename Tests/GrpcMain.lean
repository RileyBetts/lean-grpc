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

  IO.println "grpcTests OK"
