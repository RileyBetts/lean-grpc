/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.BE
import Bytes.Pool
import Grpc.Compression

namespace Grpc
namespace Message

/-- Length-prefixed gRPC message: Compressed-Flag (1) + Length (4 BE) + Message. -/
def encode (payload : ByteArray) (alg : Compression.Algorithm := .identity) : Except String ByteArray := do
  let body ← Compression.compress alg payload
  let compressed := alg != .identity
  let mut out := ByteArray.empty
  out := out.push (if compressed then 1 else 0)
  out := Bytes.Pool.pushBytes out (Bytes.BE.u32Bytes body.size.toUInt32)
  out := Bytes.Pool.pushBytes out body
  return out

/-- Encode with peer-compatible gzip when requested. -/
def encodeIO (payload : ByteArray) (alg : Compression.Algorithm := .identity) : IO ByteArray := do
  let body ← Compression.compressIO alg payload
  let compressed := alg != .identity
  let mut out := ByteArray.empty
  out := out.push (if compressed then 1 else 0)
  out := Bytes.Pool.pushBytes out (Bytes.BE.u32Bytes body.size.toUInt32)
  out := Bytes.Pool.pushBytes out body
  return out

/-- Identity encode (always succeeds). -/
def encodeId (payload : ByteArray) : ByteArray :=
  match encode payload .identity with
  | .ok b => b
  | .error _ => ByteArray.empty

/-- Decode one message; returns payload and remaining bytes.
    `alg` is the algorithm advertised via `grpc-encoding` for compressed frames
    (defaults to gzip, the common case). -/
def decodeOne (buf : Bytes.Slice) (allowGzip : Bool := true)
    (alg : Compression.Algorithm := .gzip) : Except String (ByteArray × Bytes.Slice) := do
  if buf.size < 5 then throw "short grpc frame"
  let compressed := buf.get! 0 != 0
  let len ← Bytes.BE.readU32 buf 1 |>.elim (throw "len") pure
  let n := len.toNat
  if buf.size < 5 + n then throw "incomplete grpc message"
  let body := (buf.sub 5 n).toByteArray
  let payload ←
    if !compressed then
      pure body
    else if allowGzip then
      Compression.decompress alg body
    else
      throw "compression not supported (identity only)"
  return (payload, buf.sub (5 + n) (buf.size - 5 - n))

/-- Decode one message with peer-compatible inflate for `alg` (default gzip). -/
def decodeOneIO (buf : Bytes.Slice) (allowGzip : Bool := true)
    (alg : Compression.Algorithm := .gzip) : IO (Except String (ByteArray × Bytes.Slice)) := do
  if buf.size < 5 then return .error "short grpc frame"
  let compressed := buf.get! 0 != 0
  match Bytes.BE.readU32 buf 1 with
  | none => return .error "len"
  | some len =>
    let n := len.toNat
    if buf.size < 5 + n then return .error "incomplete grpc message"
    let body := (buf.sub 5 n).toByteArray
    let rest := buf.sub (5 + n) (buf.size - 5 - n)
    if !compressed then
      return .ok (body, rest)
    else if !allowGzip then
      return .error "compression not supported (identity only)"
    else
      match ← Compression.decompressIO alg body with
      | .error e => return .error e
      | .ok payload => return .ok (payload, rest)

/-- Decode all messages in a buffer. -/
def decodeAll (buf : Bytes.Slice) (allowGzip : Bool := true)
    (alg : Compression.Algorithm := .gzip) : Except String (Array ByteArray) := do
  let mut s := buf
  let mut out : Array ByteArray := #[]
  while !s.isEmpty do
    let (p, rest) ← decodeOne s allowGzip alg
    out := out.push p
    s := rest
  return out

/-- Decode all messages, preferring peer inflate for `alg` (default gzip) on compressed frames. -/
def decodeAllIO (buf : Bytes.Slice) (allowGzip : Bool := true)
    (alg : Compression.Algorithm := .gzip) : IO (Except String (Array ByteArray)) := do
  let mut s := buf
  let mut out : Array ByteArray := #[]
  while !s.isEmpty do
    match ← decodeOneIO s allowGzip alg with
    | .error e => return .error e
    | .ok (p, rest) =>
      out := out.push p
      s := rest
  return .ok out

/-- Decode all messages preserving each frame's Compressed-Flag. -/
def decodeAllWithFlagsIO (buf : Bytes.Slice) (allowGzip : Bool := true)
    (alg : Compression.Algorithm := .gzip) :
    IO (Except String (Array (Bool × ByteArray))) := do
  let mut s := buf
  let mut out : Array (Bool × ByteArray) := #[]
  while !s.isEmpty do
    if s.size < 5 then return .error "short grpc frame"
    let compressed := s.get! 0 != 0
    match ← decodeOneIO s allowGzip alg with
    | .error e => return .error e
    | .ok (p, rest) =>
      out := out.push (compressed, p)
      s := rest
  return .ok out

end Message
end Grpc
