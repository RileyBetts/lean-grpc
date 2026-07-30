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
  deriving Inhabited

namespace Client

def unaryCall (c : H2.ClientConn) (service method : String) (authority : String)
    (request : ByteArray) : IO CallResult := do
  let headers : Array Hpack.HeaderField := #[
    Metadata.methodPost,
    Metadata.schemeHttp,
    ⟨Metadata.ascii ":authority", Metadata.ascii authority⟩,
    Metadata.path service method,
    Metadata.contentTypeGrpc,
    Metadata.teTrailers
  ]
  let body := Message.encode request
  let (respHeaders, respData) ← H2.Client.unary c headers body
  let mut code : StatusCode := .ok
  let mut msg := ""
  for h in respHeaders do
    let (n, v) :=
      (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
       String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))
    if n == "grpc-status" then
      code := StatusCode.ofUInt32 (v.toNat?.getD 0).toUInt32
    if n == "grpc-message" then
      msg := v
  let payloads ←
    match Message.decodeAll (Bytes.Slice.ofByteArray respData) with
    | .ok ps => pure ps
    | .error _ => pure #[]
  let message := payloads.getD 0 ByteArray.empty
  return { status := ⟨code, msg⟩, message, headers := respHeaders }

end Client
end Grpc
