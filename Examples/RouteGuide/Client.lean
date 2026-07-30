/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto
import H2
import Bytes.Slice
import Bytes.Pool

private def headers (host method : String) : Array Hpack.HeaderField := #[
  Grpc.Metadata.methodPost,
  Grpc.Metadata.schemeHttp,
  ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
  Grpc.Metadata.path "routeguide.RouteGuide" method,
  Grpc.Metadata.contentTypeGrpc,
  Grpc.Metadata.teTrailers
]

def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50052").toNat?.getD 50052 |>.toUInt16
  let ch ← Grpc.Channel.connectH2c host port
  let c ← Grpc.Channel.get ch

  -- GetFeature
  let r1 ← H2.Client.unary c (headers host "GetFeature") (Grpc.Message.encodeId ByteArray.empty)
  IO.println s!"GetFeature bytes={r1.data.size}"

  -- ListFeatures (server streaming)
  let r2 ← H2.Client.unary c (headers host "ListFeatures") (Grpc.Message.encodeId ByteArray.empty)
  let feats ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray r2.data))
  IO.println s!"ListFeatures count={feats.size}"

  -- RecordRoute (client streaming)
  let mut body := ByteArray.empty
  for _ in [:3] do
    body := Bytes.Pool.pushBytes body (Grpc.Message.encodeId ByteArray.empty)
  let r3 ← H2.Client.unary c (headers host "RecordRoute") body
  IO.println s!"RecordRoute bytes={r3.data.size}"

  -- RouteChat (bidi echo)
  let note := Proto.Wire.encodeString ByteArray.empty 2 "hello"
  let r4 ← H2.Client.unary c (headers host "RouteChat") (Grpc.Message.encodeId note)
  let notes ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray r4.data))
  IO.println s!"RouteChat echo count={notes.size}"
  IO.println "routeGuide client OK"
