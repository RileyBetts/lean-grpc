/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.BE
import Bytes.Pool
import Grpc
import Grpc.Codegen.Emit
import Grpc.Xds.Discovery
import H2

/-- Build a tiny gzip bomb: highly compressible zeros under wire max, expands past maxMsgSize. -/
private def gzipBombFrame (uncompSize : Nat) : IO ByteArray := do
  let zeros := ByteArray.mk (Array.replicate uncompSize 0)
  let body ← Grpc.Compression.gzipEncodePeer zeros
  -- Compressed-Flag=1 + length + body
  let mut out := ByteArray.empty
  out := out.push 1
  out := Bytes.Pool.pushBytes out (Bytes.BE.u32Bytes body.size.toUInt32)
  out := Bytes.Pool.pushBytes out body
  return out

def main : IO Unit := do
  -- LGSEC-2026-04: decompress capped at maxMsgSize
  let bomb ← gzipBombFrame (8 * 1024 * 1024)
  if bomb.size > 4 * 1024 * 1024 + 5 then
    throw (IO.userError "bomb fixture unexpectedly exceeds wire max")
  match ← Grpc.Message.decodeAllIO (Bytes.Slice.ofByteArray bomb) true .gzip (4 * 1024 * 1024) with
  | .ok _ => throw (IO.userError "expected gzip bomb to fail maxMsgSize")
  | .error e =>
    if e != "decompressed message too large" then
      throw (IO.userError s!"unexpected bomb error: {e}")

  -- LGSEC-2026-09: SDS path allowlist
  if Grpc.Xds.Discovery.sdsPathAllowed "/etc/passwd" "/var/run/secrets" then
    throw (IO.userError "SDS should reject /etc/passwd")
  if Grpc.Xds.Discovery.sdsPathAllowed "/var/run/secrets/../etc/passwd" "/var/run/secrets" then
    throw (IO.userError "SDS should reject .. traversal")
  if !Grpc.Xds.Discovery.sdsPathAllowed "/var/run/secrets/tls/cert.pem" "/var/run/secrets" then
    throw (IO.userError "SDS should allow path under root")

  -- LGSEC-2026-20: codegen identifier allowlist
  if Grpc.Codegen.safeLeanIdent "HelloRequest" != true then
    throw (IO.userError "safeLeanIdent HelloRequest")
  if Grpc.Codegen.safeLeanIdent "evil\n#eval" then
    throw (IO.userError "safeLeanIdent should reject injection")
  if Grpc.Codegen.safeLeanIdent "" then
    throw (IO.userError "safeLeanIdent empty")

  -- LGSEC-2026-06: DATA beyond recv window → FLOW_CONTROL_ERROR (GOAWAY)
  let st0 := H2.ConnState.create
  let sid : UInt32 := 1
  let s0 := H2.Stream.create sid 10 10  -- tiny recv window
  let s := { s0 with state := .open, gotHeaders := true, endHeaders := true }
  let st1 := { st0 with recvConnWindow := 10 }.upsertStream s
  let payload := ByteArray.mk (Array.replicate 64 0)
  let f := H2.Frame.data sid payload false
  match H2.handleFrame st1 f with
  | .error e => throw (IO.userError s!"handleFrame error {e}")
  | .ok (st2, outs) =>
    if !st2.wentAway then throw (IO.userError "expected flow-control GOAWAY")
    let hasGoAway := outs.any (fun fr => fr.type == .goAway)
    if !hasGoAway then throw (IO.userError "expected GOAWAY frame")

  -- LGSEC-2026-07: oversized header block → ENHANCE_YOUR_CALM
  let stH := H2.ConnState.create { ourSettings := { maxHeaderListSize := 64 } }
  let big := ByteArray.mk (Array.replicate 128 0x61)
  let hf := H2.Frame.headers 1 big true true
  match H2.handleFrame stH hf with
  | .error e => throw (IO.userError s!"headers handleFrame {e}")
  | .ok (stH2, _) =>
    if !stH2.wentAway then throw (IO.userError "expected header-list GOAWAY")

  IO.println "securityTests OK"
