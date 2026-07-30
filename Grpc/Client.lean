/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import H2
import Hpack
import Grpc.Status
import Grpc.Message
import Grpc.Metadata

namespace Grpc

structure CallResult where
  status : Status
  message : ByteArray
  headers : Array Hpack.HeaderField
  trailers : Array Hpack.HeaderField
  deriving Inhabited

namespace Client

private def headerAscii (h : Hpack.HeaderField) : String × String :=
  (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
   String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))

private def statusFromHeaders (headers trailers : Array Hpack.HeaderField) : Status :=
  Id.run do
    let mut code : StatusCode := .ok
    let mut msg := ""
    let mut httpStatus := ""
    for h in headers do
      let (n, v) := headerAscii h
      if n == ":status" then httpStatus := v
      if n == "grpc-status" then
        code := StatusCode.ofUInt32 (v.toNat?.getD 0).toUInt32
      if n == "grpc-message" then
        msg := Metadata.percentDecode v
    for h in trailers do
      let (n, v) := headerAscii h
      if n == "grpc-status" then
        code := StatusCode.ofUInt32 (v.toNat?.getD 0).toUInt32
      if n == "grpc-message" then
        msg := Metadata.percentDecode v
    if httpStatus != "" && httpStatus != "200" then
      if code == .ok then
        code := .unknown
        if msg.isEmpty then msg := s!"HTTP {httpStatus}"
    return ⟨code, msg⟩

def unaryCall (c : H2.ClientConn) (service method : String) (authority : String)
    (request : ByteArray) (extraHeaders : Array Hpack.HeaderField := #[]) : IO CallResult := do
  let headers : Array Hpack.HeaderField :=
    #[
      Metadata.methodPost,
      Metadata.schemeHttp,
      ⟨Metadata.ascii ":authority", Metadata.ascii authority⟩,
      Metadata.path service method,
      Metadata.contentTypeGrpc,
      Metadata.teTrailers
    ] ++ extraHeaders
  let body := Message.encodeId request
  let resp ← H2.Client.unary c headers body
  let status := statusFromHeaders resp.headers resp.trailers
  let payloads ←
    match Message.decodeAll (Bytes.Slice.ofByteArray resp.data) with
    | .ok ps => pure ps
    | .error _ => pure #[]
  let message := payloads.getD 0 ByteArray.empty
  return { status, message, headers := resp.headers, trailers := resp.trailers }

end Client
end Grpc
