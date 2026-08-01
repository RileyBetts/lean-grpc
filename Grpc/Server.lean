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
import Grpc.Tls

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

/-- Build the transport-agnostic `H2.StreamHandler` for `s`, shared by the
    plaintext (`serveH2c`) and TLS (`serveTls`) entry points below. -/
def handlerFor (s : Server) : H2.StreamHandler := fun _streamId headers data endStream headersSent => do
    if headersSent && !endStream && data.isEmpty then
      return { finished := false }
    -- Resolve path early so incremental bidi can respond before half-close.
    let path0 :=
      Id.run do
        for h in headers do
          let (n, v) := headerAscii h
          if n == ":path" then return v
        return ""
    let earlyBidi :=
      match findHandler s path0 with
      | some (.bidi _) => true
      | _ => false
    -- Non-bidi handlers wait for client half-close (buffered stream API).
    if !endStream && !earlyBidi then
      return { finished := false }
    if !endStream && earlyBidi && data.isEmpty then
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
      -- PROTOCOL-HTTP2: unsupported media type → HTTP 415 (trailers-only style).
      return {
        headers := Metadata.http415
        finished := true
      }
    if let some ms := Metadata.parseTimeoutMs timeout then
      if ms == 0 then
        return {
          headers := Metadata.trailersOnly (.deadlineExceeded)
          finished := true
        }
    let respAlg := Compression.negotiate acceptEnc
    match findHandler s path with
    | none =>
      return {
        headers := Metadata.trailersOnly (.unimplemented s!"unknown {path}")
        finished := true
      }
    | some mh =>
      if data.size > s.maxMsgSize + 5 then
        return {
          headers := Metadata.http200
          trailers := Metadata.statusHeaders (.resourceExhausted "message too large")
          finished := true
        }
      -- Peer-compatible inflate when Compressed-Flag is set, using the algorithm the
      -- client declared via `grpc-encoding` (defaults to gzip when unset/unknown).
      let reqAlg := (Compression.Algorithm.parse? reqEnc).getD .gzip
      let payloads ←
        match ← Message.decodeAllIO (Bytes.Slice.ofByteArray data) true reqAlg with
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
        -- grpc-go (and peers) often half-close with an empty DATA+END_STREAM after
        -- prior messages were already delivered. Re-invoking the app handler with
        -- `#[ ]` would drop batch state (e.g. "not locked" after a successful
        -- incremental handshake). Finalize with trailers-only OK instead.
        if payloads.isEmpty then
          if !endStream then
            return { finished := false }
          return {
            headers := if headersSent then #[] else respHeaders
            trailers := Metadata.statusHeaders Status.ok
            finished := true
          }
        let (msgs, st) ← h payloads
        if endStream then
          return {
            headers := if headersSent then #[] else respHeaders
            body := ← encodeManyIO msgs respAlg
            trailers := Metadata.statusHeaders st
            finished := true
          }
        else
          -- Incremental duplex: emit responses while the client stream stays open.
          return {
            headers := if headersSent then #[] else respHeaders
            body := ← encodeManyIO msgs respAlg
            finished := false
          }

def serveH2c (s : Server) (cfg : H2.ServerConfig := {}) : IO Unit :=
  H2.Server.listen cfg (handlerFor s)

/-- Serve with in-process TLS+ALPN `h2` (see `Grpc.Tls.serveH2` for the
    plaintext/mTLS decision based on `tlsCfg`). -/
def serveTls (s : Server) (tlsCfg : Tls.Config) (cfg : H2.ServerConfig := {}) : IO Unit :=
  Tls.serveH2 tlsCfg cfg (handlerFor s)

end Server
end Grpc
