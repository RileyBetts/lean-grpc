/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.Pool
import Bytes.BE

namespace Grpc.Compression

inductive Algorithm where
  | identity
  | gzip
  deriving BEq, Inhabited

def Algorithm.name : Algorithm → String
  | .identity => "identity"
  | .gzip => "gzip"

def Algorithm.parse? : String → Option Algorithm
  | "identity" => some .identity
  | "gzip" => some .gzip
  | _ => none

/-- CRC32 (ISO HDLC / gzip) for gzip footer. -/
private def crc32Table : Array UInt32 := Id.run do
  let mut t : Array UInt32 := Array.replicate 256 0
  for n in [:256] do
    let mut c : UInt32 := n.toUInt32
    for _ in [:8] do
      if (c &&& 1) != 0 then
        c := (0xedb88320 : UInt32) ^^^ (c >>> 1)
      else
        c := c >>> 1
    t := t.set! n c
  return t

def crc32 (data : ByteArray) : UInt32 :=
  Id.run do
    let mut c : UInt32 := 0xffffffff
    for i in [:data.size] do
      let b := data.get! i
      let idx := ((c ^^^ b.toUInt32) &&& 255).toNat
      c := crc32Table[idx]! ^^^ (c >>> 8)
    return c ^^^ 0xffffffff

/-- Stored-deflate gzip (self-tests / peers that accept stored blocks). -/
def gzipEncodeStored (payload : ByteArray) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    out := Bytes.Pool.pushBytes out (ByteArray.mk #[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
    let mut off := 0
    while off < payload.size || (off == 0 && payload.size == 0) do
      let take := min 65535 (payload.size - off)
      let last := off + take ≥ payload.size
      let hdr : UInt8 := if last then 0x01 else 0x00
      out := out.push hdr
      let l := take
      let nl := 65535 - l
      out := out.push (l % 256).toUInt8
      out := out.push (l / 256).toUInt8
      out := out.push (nl % 256).toUInt8
      out := out.push (nl / 256).toUInt8
      out := Bytes.Pool.pushBytes out (payload.extract off (off + take))
      off := off + take
      if payload.size == 0 then break
    let crc := crc32 payload
    out := Bytes.Pool.pushBytes out (Bytes.BE.u32BytesLE crc)
    out := Bytes.Pool.pushBytes out (Bytes.BE.u32BytesLE payload.size.toUInt32)
    return out

def gzipDecodeStored (data : ByteArray) : Except String ByteArray := do
  if data.size < 18 then throw "short gzip"
  if data.get! 0 != 0x1f || data.get! 1 != 0x8b then throw "bad gzip magic"
  if data.get! 2 != 0x08 then throw "bad gzip cm"
  let mut pos : Nat := 10
  let mut out := ByteArray.empty
  let mut done := false
  while !done do
    if pos ≥ data.size then throw "trunc deflate"
    let hdr := data.get! pos
    pos := pos + 1
    let bfinal := (hdr &&& 1) != 0
    let btype := (hdr >>> 1) &&& 3
    if btype != 0 then throw "only stored deflate blocks supported"
    if pos + 4 > data.size then throw "trunc len"
    let len := (data.get! pos).toNat + ((data.get! (pos+1)).toNat * 256)
    let nlen := (data.get! (pos+2)).toNat + ((data.get! (pos+3)).toNat * 256)
    if (len ^^^ nlen) != 0xffff then throw "bad nlen"
    pos := pos + 4
    if pos + len > data.size then throw "trunc block"
    out := Bytes.Pool.pushBytes out (data.extract pos (pos + len))
    pos := pos + len
    done := bfinal
  if pos + 8 > data.size then throw "trunc footer"
  let expectCrc ← Bytes.BE.readU32LE (Bytes.Slice.ofByteArray data) pos |>.elim (throw "crc") pure
  let got := crc32 out
  if expectCrc != got then throw "crc mismatch"
  return out

/-- Peer-compatible gzip via system `gzip` (real deflate). Falls back to stored encode. -/
def gzipEncodePeer (payload : ByteArray) : IO ByteArray := do
  try
    let child ← IO.Process.spawn {
      cmd := "gzip"
      args := #["-c", "-n"]
      stdin := .piped
      stdout := .piped
      stderr := .piped
    }
    let (stdin, child) ← child.takeStdin
    stdin.write payload
    stdin.flush
    let stdout ← IO.asTask (child.stdout.readBinToEnd) Task.Priority.dedicated
    let _ ← child.stderr.readBinToEnd
    let code ← child.wait
    let out ← IO.ofExcept stdout.get
    if code != 0 || (out.isEmpty && !payload.isEmpty) then
      return gzipEncodeStored payload
    return out
  catch _ =>
    return gzipEncodeStored payload

/-- Peer-compatible gunzip via system `gzip -dc`; falls back to stored decoder. -/
def gzipDecodePeer (data : ByteArray) : IO (Except String ByteArray) := do
  try
    let child ← IO.Process.spawn {
      cmd := "gzip"
      args := #["-dc"]
      stdin := .piped
      stdout := .piped
      stderr := .piped
    }
    let (stdin, child) ← child.takeStdin
    stdin.write data
    stdin.flush
    let stdout ← IO.asTask (child.stdout.readBinToEnd) Task.Priority.dedicated
    let _ ← child.stderr.readBinToEnd
    let code ← child.wait
    let out ← IO.ofExcept stdout.get
    if code != 0 then
      return gzipDecodeStored data
    return .ok out
  catch _ =>
    return gzipDecodeStored data

def compress (alg : Algorithm) (payload : ByteArray) : Except String ByteArray :=
  match alg with
  | .identity => .ok payload
  | .gzip => .ok (gzipEncodeStored payload)

def decompress (alg : Algorithm) (payload : ByteArray) : Except String ByteArray :=
  match alg with
  | .identity => .ok payload
  | .gzip => gzipDecodeStored payload

/-- IO variants that prefer peer-compatible gzip. -/
def compressIO (alg : Algorithm) (payload : ByteArray) : IO ByteArray := do
  match alg with
  | .identity => pure payload
  | .gzip => gzipEncodePeer payload

def decompressIO (alg : Algorithm) (payload : ByteArray) : IO (Except String ByteArray) := do
  match alg with
  | .identity => pure (.ok payload)
  | .gzip => gzipDecodePeer payload

private def trimAsciiSpaces (s : String) : String :=
  let cs := s.toList.dropWhile (fun c => c == ' ' || c == '\t')
  let cs := (cs.reverse.dropWhile (fun c => c == ' ' || c == '\t')).reverse
  String.ofList cs

/-- Prefer gzip when advertised; otherwise identity. -/
def negotiate (acceptEncoding : String) : Algorithm :=
  if acceptEncoding.splitOn "," |>.any (fun s => trimAsciiSpaces s == "gzip") then .gzip
  else .identity

end Grpc.Compression
