/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.Pool
import H2
import Hpack
import Proto
import Grpc.Status
import Grpc.Message
import Grpc.Metadata
import Grpc.Stream
import Grpc.Compression

namespace Grpc

/-- Unary handler: request bytes → response bytes + status. -/
abbrev UnaryHandler := ByteArray → IO (ByteArray × Status)

inductive MethodHandler where
  | unary (h : UnaryHandler)
  | serverStream (h : Stream.ServerStreamHandler)
  | clientStream (h : Stream.ClientStreamHandler)
  | bidi (h : Stream.BidiStreamHandler)

structure ServiceMethod where
  service : String
  method : String
  handler : MethodHandler

structure Server where
  methods : Array ServiceMethod
  maxMsgSize : Nat := 4 * 1024 * 1024
  deriving Inhabited

namespace Server

def empty : Server := ⟨#[], 4 * 1024 * 1024⟩

def register (s : Server) (service method : String) (h : UnaryHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, .unary h⟩ }

def registerServerStream (s : Server) (service method : String) (h : Stream.ServerStreamHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, .serverStream h⟩ }

def registerClientStream (s : Server) (service method : String) (h : Stream.ClientStreamHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, .clientStream h⟩ }

def registerBidi (s : Server) (service method : String) (h : Stream.BidiStreamHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, .bidi h⟩ }

private def findHandler (s : Server) (path : String) : Option MethodHandler :=
  Id.run do
    for m in s.methods do
      let p := s!"/{m.service}/{m.method}"
      if p == path then return some m.handler
    return none

private def headerAscii (h : Hpack.HeaderField) : String × String :=
  (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
   String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))

/-- Deprecated alias — use `Metadata.parseTimeoutMs`. -/
def parseTimeoutMs (t : String) : Option Nat := Metadata.parseTimeoutMs t

private def encodeManyIO (msgs : Array ByteArray) (alg : Compression.Algorithm) : IO ByteArray := do
  let mut out := ByteArray.empty
  for m in msgs do
    out := Bytes.Pool.pushBytes out (← Message.encodeIO m alg)
  return out

def serveH2c (s : Server) (cfg : H2.ServerConfig := {}) : IO Unit := do
  let handler : H2.StreamHandler := fun _streamId headers data endStream headersSent => do
    if headersSent && !endStream then
      return { finished := false }
    -- Streaming methods that need incremental bidi still use raw H2 handlers in interop;
    -- registered handlers wait for client half-close (buffered stream API).
    if !endStream then
      return { finished := false }
    let mut path := ""
    let mut contentType := ""
    let mut timeout := ""
    let mut acceptEnc := "identity"
    let mut reqEnc := "identity"
    for h in headers do
      let (n, v) := headerAscii h
      if n == ":path" then path := v
      if n == "content-type" then contentType := v
      if n == "grpc-timeout" then timeout := v
      if n == "grpc-accept-encoding" then acceptEnc := v
      if n == "grpc-encoding" then reqEnc := v
    if !(contentType.isEmpty || "application/grpc".isPrefixOf contentType) then
      return {
        headers := Metadata.http200
        trailers := Metadata.statusHeaders (.internal "bad content-type")
        finished := true
      }
    if let some ms := Metadata.parseTimeoutMs timeout then
      if ms == 0 then
        return {
          headers := Metadata.http200
          trailers := Metadata.statusHeaders (.deadlineExceeded)
          finished := true
        }
    let respAlg := Compression.negotiate acceptEnc
    match findHandler s path with
    | none =>
      return {
        headers := Metadata.http200
        trailers := Metadata.statusHeaders (.unimplemented s!"unknown {path}")
        finished := true
      }
    | some mh =>
      if data.size > s.maxMsgSize + 5 then
        return {
          headers := Metadata.http200
          trailers := Metadata.statusHeaders (.resourceExhausted "message too large")
          finished := true
        }
      -- Peer gzip inflate when Compressed-Flag is set (grpc-encoding is advisory).
      let _ := reqEnc
      let payloads ←
        match ← Message.decodeAllIO (Bytes.Slice.ofByteArray data) with
        | .ok ps => pure ps
        | .error e =>
          return {
            headers := Metadata.http200
            trailers := Metadata.statusHeaders (.internal e)
            finished := true
          }
      let mut respHeaders := Metadata.http200
      if respAlg != .identity then
        respHeaders := respHeaders.push (Metadata.grpcEncoding respAlg.name)
      match mh with
      | .unary h =>
        let req := payloads.getD 0 ByteArray.empty
        if req.size > s.maxMsgSize then
          return {
            headers := Metadata.http200
            trailers := Metadata.statusHeaders (.resourceExhausted "message too large")
            finished := true
          }
        let (resp, st) ← h req
        let body ←
          if st.code != .ok && resp.isEmpty then pure ByteArray.empty
          else Message.encodeIO resp respAlg
        return {
          headers := respHeaders
          body
          trailers := Metadata.statusHeaders st
          finished := true
        }
      | .serverStream h =>
        let req := payloads.getD 0 ByteArray.empty
        let (msgs, st) ← h req
        return {
          headers := respHeaders
          body := ← encodeManyIO msgs respAlg
          trailers := Metadata.statusHeaders st
          finished := true
        }
      | .clientStream h =>
        let (resp, st) ← h payloads
        let body ←
          if st.code != .ok && resp.isEmpty then pure ByteArray.empty
          else Message.encodeIO resp respAlg
        return {
          headers := respHeaders
          body
          trailers := Metadata.statusHeaders st
          finished := true
        }
      | .bidi h =>
        let (msgs, st) ← h payloads
        return {
          headers := respHeaders
          body := ← encodeManyIO msgs respAlg
          trailers := Metadata.statusHeaders st
          finished := true
        }
  H2.Server.listen cfg handler

end Server
end Grpc
