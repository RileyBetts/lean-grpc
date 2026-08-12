/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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
import Grpc.PeerIdentity
import Grpc.Stream
import Grpc.Compression
import Grpc.Tls
import Std.Async

open Std.Async

namespace Grpc

/-- Unary handler: request bytes → response bytes + status. -/
abbrev UnaryHandler := ByteArray → IO (ByteArray × Status)

/-- Unary handler with per-RPC `ServerCallContext` (peer identity + inbound metadata). -/
abbrev UnaryHandlerWithContext := ServerCallContext → ByteArray → IO (ByteArray × Status)

inductive MethodHandler where
  | unary (h : UnaryHandlerWithContext)
  | serverStream (h : Stream.ServerStreamHandler)
  | clientStream (h : Stream.ClientStreamHandler)
  | bidi (h : Stream.BidiStreamHandler)
  /-- Context-aware streaming variants (v1.5.0 — mTLS IAM parity). -/
  | serverStreamCtx (h : Stream.ServerStreamHandlerWithContext)
  | clientStreamCtx (h : Stream.ClientStreamHandlerWithContext)
  | bidiCtx (h : Stream.BidiStreamHandlerWithContext)

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

/-- Register a unary method that receives `ServerCallContext` (mTLS peer identity + metadata). -/
def registerWithContext (s : Server) (service method : String) (h : UnaryHandlerWithContext) : Server :=
  { s with methods := s.methods.push ⟨service, method, .unary h⟩ }

/-- Body-only unary register (ignores context). Prefer `registerWithContext` for AuthN. -/
def register (s : Server) (service method : String) (h : UnaryHandler) : Server :=
  registerWithContext s service method (fun _ctx req => h req)

def registerServerStream (s : Server) (service method : String) (h : Stream.ServerStreamHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, .serverStream h⟩ }

def registerClientStream (s : Server) (service method : String) (h : Stream.ClientStreamHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, .clientStream h⟩ }

def registerBidi (s : Server) (service method : String) (h : Stream.BidiStreamHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, .bidi h⟩ }

/-- Register a server-streaming handler with `StreamCallContext` (mTLS IAM parity, v1.5.0). -/
def registerServerStreamWithContext (s : Server) (service method : String)
    (h : Stream.ServerStreamHandlerWithContext) : Server :=
  { s with methods := s.methods.push ⟨service, method, .serverStreamCtx h⟩ }

/-- Register a client-streaming handler with `StreamCallContext`. -/
def registerClientStreamWithContext (s : Server) (service method : String)
    (h : Stream.ClientStreamHandlerWithContext) : Server :=
  { s with methods := s.methods.push ⟨service, method, .clientStreamCtx h⟩ }

/-- Register a bidi-streaming handler with `StreamCallContext`. -/
def registerBidiWithContext (s : Server) (service method : String)
    (h : Stream.BidiStreamHandlerWithContext) : Server :=
  { s with methods := s.methods.push ⟨service, method, .bidiCtx h⟩ }

/-- Typed unary register: decode request, run handler, encode response. -/
def registerTyped (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : α → IO (β × Status)) : Server :=
  register s service method fun reqBytes => do
    match decode reqBytes with
    | .error e => return (ByteArray.empty, Status.invalidArgument e)
    | .ok req =>
      let (resp, st) ← h req
      return (encode resp, st)

/-- Typed unary register with `ServerCallContext`. -/
def registerTypedWithContext (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : ServerCallContext → α → IO (β × Status)) : Server :=
  registerWithContext s service method fun ctx reqBytes => do
    match decode reqBytes with
    | .error e => return (ByteArray.empty, Status.invalidArgument e)
    | .ok req =>
      let (resp, st) ← h ctx req
      return (encode resp, st)

/-- Typed server-streaming register with `StreamCallContext`. -/
def registerServerStreamTypedWithContext (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : StreamCallContext → α → IO (Array β × Status)) : Server :=
  registerServerStreamWithContext s service method fun ctx reqBytes => do
    match decode reqBytes with
    | .error e => return (#[], Status.invalidArgument e)
    | .ok req =>
      let (resps, st) ← h ctx req
      return (resps.map encode, st)

/-- Typed client-streaming register with `StreamCallContext`. -/
def registerClientStreamTypedWithContext (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : StreamCallContext → Array α → IO (β × Status)) : Server :=
  registerClientStreamWithContext s service method fun ctx reqBytes => do
    let mut reqs : Array α := #[]
    for b in reqBytes do
      match decode b with
      | .error e => return (ByteArray.empty, Status.invalidArgument e)
      | .ok r => reqs := reqs.push r
    let (resp, st) ← h ctx reqs
    return (encode resp, st)

/-- Typed bidi-streaming register with `StreamCallContext`. -/
def registerBidiTypedWithContext (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : StreamCallContext → Array α → IO (Array β × Status)) : Server :=
  registerBidiWithContext s service method fun ctx reqBytes => do
    let mut reqs : Array α := #[]
    for b in reqBytes do
      match decode b with
      | .error e => return (#[], Status.invalidArgument e)
      | .ok r => reqs := reqs.push r
    let (resps, st) ← h ctx reqs
    return (resps.map encode, st)

/-- Typed server-streaming register (still batch: one request → array of responses). -/
def registerServerStreamTyped (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : α → IO (Array β × Status)) : Server :=
  registerServerStream s service method fun reqBytes => do
    match decode reqBytes with
    | .error e => return (#[], Status.invalidArgument e)
    | .ok req =>
      let (resps, st) ← h req
      return (resps.map encode, st)

/-- Typed client-streaming register (batch: array of requests → one response). -/
def registerClientStreamTyped (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : Array α → IO (β × Status)) : Server :=
  registerClientStream s service method fun reqBytes => do
    let mut reqs : Array α := #[]
    for b in reqBytes do
      match decode b with
      | .error e => return (ByteArray.empty, Status.invalidArgument e)
      | .ok r => reqs := reqs.push r
    let (resp, st) ← h reqs
    return (encode resp, st)

/-- Typed bidi register (batch arrays both ways). -/
def registerBidiTyped (s : Server) (service method : String)
    (decode : ByteArray → Except String α) (encode : β → ByteArray)
    (h : Array α → IO (Array β × Status)) : Server :=
  registerBidi s service method fun reqBytes => do
    let mut reqs : Array α := #[]
    for b in reqBytes do
      match decode b with
      | .error e => return (#[], Status.invalidArgument e)
      | .ok r => reqs := reqs.push r
    let (resps, st) ← h reqs
    return (resps.map encode, st)

private def findHandler (s : Server) (path : String) : Option MethodHandler :=
  Id.run do
    for m in s.methods do
      let p := s!"/{m.service}/{m.method}"
      if p == path then return some m.handler
    return none

private def headerAscii (h : Hpack.HeaderField) : String × String :=
  (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
   String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))

/-- Collect non-pseudo request headers into `Metadata` (HTTP/2 names are lowercased). -/
private def metadataFromHeaders (headers : Array Hpack.HeaderField) : Metadata :=
  Id.run do
    let mut m := Metadata.empty
    for h in headers do
      let (n, v) := headerAscii h
      if !n.startsWith ":" then
        m := m.add n v
    return m

/-- Deprecated alias — use `Metadata.parseTimeoutMs`. -/
def parseTimeoutMs (t : String) : Option Nat := Metadata.parseTimeoutMs t

private def encodeManyIO (msgs : Array ByteArray) (alg : Compression.Algorithm) : IO ByteArray := do
  let mut out := ByteArray.empty
  for m in msgs do
    out := Bytes.Pool.pushBytes out (← Message.encodeIO m alg)
  return out

/-- Build the transport-agnostic `H2.StreamHandler` for `s`.
    `peerIdentity` is connection-scoped (from mTLS); `mtlsRequired` is true when
    the listener was configured with `clientCaPath`. -/
def handlerFor (s : Server) (peerIdentity : Option PeerIdentity := none)
    (mtlsRequired : Bool := false) : H2.StreamHandler := fun _streamId headers data endStream headersSent => do
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
    -- PROTOCOL-HTTP2: require application/grpc with optional +proto/+json (or ;params).
    let ctOk :=
      contentType == "application/grpc" ||
        contentType.startsWith "application/grpc+" ||
        contentType.startsWith "application/grpc;"
    if contentType.isEmpty || !ctOk then
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
        match ← Message.decodeAllIO (Bytes.Slice.ofByteArray data) true reqAlg s.maxMsgSize with
        | .ok ps => pure ps
        | .error e =>
          let st :=
            if e == "decompressed message too large" then
              Status.resourceExhausted e
            else
              Status.internal e
          return {
            headers := Metadata.http200
            trailers := Metadata.statusHeaders st
            finished := true
          }
      let mut respHeaders := Metadata.http200
      if respAlg != .identity then
        respHeaders := respHeaders.push (Metadata.grpcEncoding respAlg.name)
      let ctx : ServerCallContext := {
        peerIdentity
        metadata := metadataFromHeaders headers
        methodPath := path
        mtlsRequired
      }
      match mh with
      | .unary h =>
        let req := payloads.getD 0 ByteArray.empty
        let (resp, st) ← h ctx req
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
      | .serverStreamCtx h =>
        let req := payloads.getD 0 ByteArray.empty
        let (msgs, st) ← h ctx req
        return {
          headers := respHeaders
          body := ← encodeManyIO msgs respAlg
          trailers := Metadata.statusHeaders st
          finished := true
        }
      | .clientStreamCtx h =>
        let (resp, st) ← h ctx payloads
        let body ←
          if st.code != .ok && resp.isEmpty then pure ByteArray.empty
          else Message.encodeIO resp respAlg
        return {
          headers := respHeaders
          body
          trailers := Metadata.statusHeaders st
          finished := true
        }
      | .bidiCtx h =>
        if payloads.isEmpty then
          if !endStream then
            return { finished := false }
          return {
            headers := if headersSent then #[] else respHeaders
            trailers := Metadata.statusHeaders Status.ok
            finished := true
          }
        let (msgs, st) ← h ctx payloads
        if endStream then
          return {
            headers := if headersSent then #[] else respHeaders
            body := ← encodeManyIO msgs respAlg
            trailers := Metadata.statusHeaders st
            finished := true
          }
        else
          return {
            headers := if headersSent then #[] else respHeaders
            body := ← encodeManyIO msgs respAlg
            finished := false
          }

def serveH2c (s : Server) (cfg : H2.ServerConfig := {}) : IO Unit :=
  H2.Server.listen cfg (handlerFor s none false)

/-- Async h2c serve (accept/send/recv without `.block` on the hot path). -/
def serveH2cAsync (s : Server) (cfg : H2.ServerConfig := {}) : Async Unit :=
  H2.Server.listenAsync cfg (handlerFor s none false)

/-- Serve with in-process TLS+ALPN `h2` (see `Grpc.Tls.serveH2` for the
    plaintext/mTLS decision based on `tlsCfg`). Peer identity is extracted per
    accepted connection and threaded into unary context handlers.
    OpenSSL stays blocking FFI but runs **off** the UV loop in v1.3.0 — see docs/async-io.md. -/
def serveTls (s : Server) (tlsCfg : Tls.Config) (cfg : H2.ServerConfig := {}) : IO Unit :=
  let mtlsRequired := tlsCfg.clientCaPath.isSome
  Tls.serveH2 tlsCfg cfg fun peerId => handlerFor s peerId mtlsRequired

/-- Async TLS serve: accept/handshake/`SSL_*` off-loop; connections on `background`. -/
def serveTlsAsync (s : Server) (tlsCfg : Tls.Config) (cfg : H2.ServerConfig := {}) : Async Unit :=
  let mtlsRequired := tlsCfg.clientCaPath.isSome
  Tls.serveH2Async tlsCfg cfg fun peerId => handlerFor s peerId mtlsRequired

end Server
end Grpc
