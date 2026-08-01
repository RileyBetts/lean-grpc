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
import Grpc.Compression

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

/-- Parse `grpc-status`/`grpc-message`/`grpc-status-details-bin` (and the `:status`
    fallback for non-gRPC HTTP errors) out of response headers/trailers. -/
def statusFromHeaders (headers trailers : Array Hpack.HeaderField) : Status :=
  Id.run do
    let mut code : StatusCode := .ok
    let mut msg := ""
    let mut httpStatus := ""
    let mut detailsBin : Option ByteArray := none
    for h in headers do
      let (n, v) := headerAscii h
      if n == ":status" then httpStatus := v
      if n == "grpc-status" then
        code := StatusCode.ofUInt32 (v.toNat?.getD 0).toUInt32
      if n == "grpc-message" then
        msg := Metadata.percentDecode v
      if n == "grpc-status-details-bin" then
        match Metadata.base64Decode v with
        | .ok b => detailsBin := some b
        | .error _ => pure ()
    for h in trailers do
      let (n, v) := headerAscii h
      if n == "grpc-status" then
        code := StatusCode.ofUInt32 (v.toNat?.getD 0).toUInt32
      if n == "grpc-message" then
        msg := Metadata.percentDecode v
      if n == "grpc-status-details-bin" then
        match Metadata.base64Decode v with
        | .ok b => detailsBin := some b
        | .error _ => pure ()
    if httpStatus == "415" then
      code := .invalidArgument
      if msg.isEmpty then msg := "unsupported media type"
    else if httpStatus != "" && httpStatus != "200" then
      if code == .ok then
        code := .unknown
        if msg.isEmpty then msg := s!"HTTP {httpStatus}"
    -- Details only valid when status ≠ OK.
    let details := if code == .ok then none else detailsBin
    return { code, message := msg, detailsBin := details }

/-- Send a unary call's HEADERS+DATA and return its stream id (plus any parsed
    `grpc-timeout` deadline) without waiting for a response. Exposed so callers
    that need the stream id while the call is still in flight — e.g. parallel
    hedging, which must be able to `H2.Client.resetStream` a losing attempt —
    can do so; `unaryCall` composes this with `finishUnary` for the common case. -/
def startUnary (c : H2.ClientConn) (service method : String) (authority : String)
    (request : ByteArray) (extraHeaders : Array Hpack.HeaderField := #[])
    (compress : Compression.Algorithm := .identity)
    (useHttps : Bool := false) : IO (UInt32 × Option Nat) := do
  let scheme := if useHttps then Metadata.schemeHttps else Metadata.schemeHttp
  let mut headers : Array Hpack.HeaderField :=
    #[
      Metadata.methodPost,
      scheme,
      ⟨Metadata.ascii ":authority", Metadata.ascii authority⟩,
      Metadata.path service method,
      Metadata.contentTypeGrpc,
      Metadata.teTrailers,
      Metadata.userAgent,
      Metadata.grpcAcceptEncoding "identity,gzip,deflate,snappy"
    ] ++ extraHeaders
  if compress != .identity then
    headers := headers.push (Metadata.grpcEncoding compress.name)
  let body ← Message.encodeIO request compress
  let deadlineMs? : Option Nat :=
    Id.run do
      for h in extraHeaders do
        let (n, v) := headerAscii h
        if n == "grpc-timeout" then
          match Metadata.parseTimeoutMs v with
          | some ms => return some ms
          | none => pure ()
      return none
  let sid ← H2.Client.startRequest c headers body true
  return (sid, deadlineMs?)

/-- Await a call started with `startUnary` and decode it into a `CallResult`. -/
def finishUnary (c : H2.ClientConn) (streamId : UInt32) (deadlineMs? : Option Nat) :
    IO CallResult := do
  let resp ← H2.Client.awaitUnary c streamId deadlineMs?
  let status := statusFromHeaders resp.headers resp.trailers
  let respAlg :=
    Id.run do
      for h in resp.headers do
        let (n, v) := headerAscii h
        if n == "grpc-encoding" then
          if let some a := Compression.Algorithm.parse? v then return a
      return Compression.Algorithm.gzip
  let payloads ←
    match ← Message.decodeAllIO (Bytes.Slice.ofByteArray resp.data) true respAlg with
    | .ok ps => pure ps
    | .error _ => pure #[]
  let message := payloads.getD 0 ByteArray.empty
  return { status, message, headers := resp.headers, trailers := resp.trailers }

def unaryCall (c : H2.ClientConn) (service method : String) (authority : String)
    (request : ByteArray) (extraHeaders : Array Hpack.HeaderField := #[])
    (compress : Compression.Algorithm := .identity)
    (useHttps : Bool := false) : IO CallResult := do
  let (sid, deadlineMs?) ←
    startUnary c service method authority request extraHeaders compress useHttps
  finishUnary c sid deadlineMs?

end Client
end Grpc
