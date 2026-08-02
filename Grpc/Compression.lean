/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.Pool
import Bytes.BE

namespace Grpc.Compression

inductive Algorithm where
  | identity
  | gzip
  | deflate
  | snappy
  deriving BEq, Inhabited

def Algorithm.name : Algorithm → String
  | .identity => "identity"
  | .gzip => "gzip"
  | .deflate => "deflate"
  | .snappy => "snappy"

def Algorithm.parse? : String → Option Algorithm
  | "identity" => some .identity
  | "gzip" => some .gzip
  | "deflate" => some .deflate
  | "snappy" => some .snappy
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

/-- True when `p` is an absolute filesystem path (helpers must not resolve via PATH). -/
def isAbsoluteHelperPath (p : String) : Bool :=
  p.startsWith "/" ||
    match p.toList with
    | _ :: ':' :: _ => true
    | _ => false

/-- Prefer in-process zlib via `scripts/build_native.sh` helper when
    `LEAN_GRPC_ZLIB_HELPER` points at an absolute filter binary; else system `gzip`; else stored. -/
private def runFilter (cmd : String) (args : Array String) (payload : ByteArray) : IO (Option ByteArray) := do
  try
    let child ← IO.Process.spawn {
      cmd := cmd
      args := args
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
    if code != 0 || (out.isEmpty && !payload.isEmpty) then return none
    return some out
  catch _ =>
    return none

/-- Peer-compatible gzip: zlib helper → system gzip → stored deflate. -/
def gzipEncodePeer (payload : ByteArray) : IO ByteArray := do
  if let some helper := ← IO.getEnv "LEAN_GRPC_ZLIB_HELPER" then
    if isAbsoluteHelperPath helper then
      if let some out ← runFilter helper #["compress"] payload then return out
  if let some out ← runFilter "gzip" #["-c", "-n"] payload then return out
  return gzipEncodeStored payload

/-- Peer-compatible gunzip with optional uncompressed size cap (`maxOut`). -/
def gzipDecodePeer (data : ByteArray) (maxOut : Nat := 4 * 1024 * 1024) :
    IO (Except String ByteArray) := do
  if let some helper := ← IO.getEnv "LEAN_GRPC_ZLIB_HELPER" then
    if isAbsoluteHelperPath helper then
      if let some out ← runFilter helper #["decompress", toString maxOut] data then
        if out.size > maxOut then return .error "decompressed message too large"
        return .ok out
  if let some out ← runFilter "gzip" #["-dc"] data then
    if out.size > maxOut then return .error "decompressed message too large"
    return .ok out
  match gzipDecodeStored data with
  | .error e => return .error e
  | .ok out =>
    if out.size > maxOut then return .error "decompressed message too large"
    else return .ok out

/-- Adler-32 checksum (zlib/RFC 1950 footer). -/
def adler32 (data : ByteArray) : UInt32 :=
  Id.run do
    let mut a : UInt32 := 1
    let mut b : UInt32 := 0
    for i in [:data.size] do
      a := (a + (data.get! i).toUInt32) % 65521
      b := (b + a) % 65521
    return (b <<< 16) ||| a

/-- Stored-deflate zlib stream (RFC 1950 header/trailer around RFC 1951 stored blocks).
    Reuses the same stored-block body as `gzipEncodeStored`. -/
def deflateEncodeStored (payload : ByteArray) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    -- CMF=0x78 (deflate, 32K window), FLG=0x01 (no dict, fastest, valid checksum row).
    out := out.push 0x78
    out := out.push 0x01
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
    let adler := adler32 payload
    -- Adler-32 trailer is big-endian.
    out := out.push ((adler >>> 24) &&& 0xff).toUInt8
    out := out.push ((adler >>> 16) &&& 0xff).toUInt8
    out := out.push ((adler >>> 8) &&& 0xff).toUInt8
    out := out.push (adler &&& 0xff).toUInt8
    return out

def deflateDecodeStored (data : ByteArray) : Except String ByteArray := do
  if data.size < 6 then throw "short zlib stream"
  let cmf := data.get! 0
  if (cmf &&& 0x0f) != 8 then throw "bad zlib cm"
  let mut pos : Nat := 2
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
  if pos + 4 > data.size then throw "trunc adler"
  let b0 := (data.get! pos).toUInt32
  let b1 := (data.get! (pos+1)).toUInt32
  let b2 := (data.get! (pos+2)).toUInt32
  let b3 := (data.get! (pos+3)).toUInt32
  let expect := (b0 <<< 24) ||| (b1 <<< 16) ||| (b2 <<< 8) ||| b3
  if adler32 out != expect then throw "adler mismatch"
  return out

/-- Peer-compatible deflate: absolute `LEAN_GRPC_DEFLATE_HELPER` → `python3` → stored zlib. -/
def deflateEncodePeer (payload : ByteArray) : IO ByteArray := do
  if let some helper := ← IO.getEnv "LEAN_GRPC_DEFLATE_HELPER" then
    if isAbsoluteHelperPath helper then
      if let some out ← runFilter helper #["compress"] payload then return out
  if let some out ← runFilter "python3" #["-c",
      "import sys,zlib;sys.stdout.buffer.write(zlib.compress(sys.stdin.buffer.read()))"] payload then
    return out
  return deflateEncodeStored payload

def deflateDecodePeer (data : ByteArray) (maxOut : Nat := 4 * 1024 * 1024) :
    IO (Except String ByteArray) := do
  let check (out : ByteArray) : Except String ByteArray :=
    if out.size > maxOut then .error "decompressed message too large" else .ok out
  if let some helper := ← IO.getEnv "LEAN_GRPC_DEFLATE_HELPER" then
    if isAbsoluteHelperPath helper then
      if let some out ← runFilter helper #["decompress"] data then return check out
  if let some out ← runFilter "python3" #["-c",
      "import sys,zlib;sys.stdout.buffer.write(zlib.decompress(sys.stdin.buffer.read()))"] data then
    return check out
  match deflateDecodeStored data with
  | .error e => return .error e
  | .ok out => return check out

/-- Snappy varint (LEB128, little-endian groups). -/
private def snappyVarintEncode (n : Nat) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    let mut v := n
    let mut more := true
    while more do
      let b := v % 128
      v := v / 128
      if v == 0 then
        out := out.push b.toUInt8
        more := false
      else
        out := out.push (b ||| 0x80).toUInt8
    return out

private def snappyVarintDecode (data : ByteArray) (pos : Nat) : Option (Nat × Nat) :=
  Id.run do
    let mut shift := 0
    let mut result : Nat := 0
    let mut i := pos
    while true do
      if i ≥ data.size then return none
      let b := data.get! i
      result := result + ((b.toNat &&& 0x7f) <<< shift)
      i := i + 1
      if (b &&& 0x80) == 0 then return some (result, i)
      shift := shift + 7
      if shift > 63 then return none
    return none

/-- Uncompressed "literal-only" Snappy block: a genuinely valid Snappy stream
    (any conformant Snappy decoder can read literal elements), just without
    any back-reference compression. -/
def snappyEncodeLiteral (payload : ByteArray) : ByteArray :=
  Id.run do
    let mut out := snappyVarintEncode payload.size
    if payload.size == 0 then return out
    let mut off := 0
    -- Chunk into ≤ 4 GiB literal elements (tag supports up to 4 length bytes);
    -- keep chunks modest to avoid huge single allocations.
    let chunk := 1 <<< 20
    while off < payload.size do
      let take := min chunk (payload.size - off)
      let lenM1 := take - 1
      if lenM1 < 60 then
        out := out.push (lenM1 <<< 2).toUInt8
      else
        -- Smallest number of extra length bytes that fits lenM1.
        let bytesNeeded := if lenM1 < 256 then 1 else if lenM1 < 65536 then 2
          else if lenM1 < 16777216 then 3 else 4
        let tagExtra := 59 + bytesNeeded
        out := out.push (tagExtra <<< 2).toUInt8
        let mut v := lenM1
        for _ in [:bytesNeeded] do
          out := out.push (v % 256).toUInt8
          v := v / 256
      out := Bytes.Pool.pushBytes out (payload.extract off (off + take))
      off := off + take
    return out

def snappyDecodeLiteral (data : ByteArray) : Except String ByteArray := do
  match snappyVarintDecode data 0 with
  | none => throw "bad snappy preamble"
  | some (total, pos0) =>
    let mut pos := pos0
    let mut out := ByteArray.empty
    while out.size < total do
      if pos ≥ data.size then throw "trunc snappy"
      let tag := data.get! pos
      pos := pos + 1
      let kind := tag &&& 3
      if kind != 0 then throw "unsupported compressed snappy element"
      let lenM1Hi := (tag >>> 2).toNat
      let lenM1 ←
        if lenM1Hi < 60 then
          pure lenM1Hi
        else do
          let extra := lenM1Hi - 59
          if pos + extra > data.size then throw "trunc snappy len"
          let mut v : Nat := 0
          for j in [:extra] do
            v := v + ((data.get! (pos + j)).toNat <<< (8 * j))
          pos := pos + extra
          pure v
      let len := lenM1 + 1
      if pos + len > data.size then throw "trunc snappy literal"
      out := Bytes.Pool.pushBytes out (data.extract pos (pos + len))
      pos := pos + len
    return out

def compress (alg : Algorithm) (payload : ByteArray) : Except String ByteArray :=
  match alg with
  | .identity => .ok payload
  | .gzip => .ok (gzipEncodeStored payload)
  | .deflate => .ok (deflateEncodeStored payload)
  | .snappy => .ok (snappyEncodeLiteral payload)

def decompress (alg : Algorithm) (payload : ByteArray) : Except String ByteArray :=
  match alg with
  | .identity => .ok payload
  | .gzip => gzipDecodeStored payload
  | .deflate => deflateDecodeStored payload
  | .snappy => snappyDecodeLiteral payload

/-- IO variants that prefer peer-compatible codecs where available. -/
def compressIO (alg : Algorithm) (payload : ByteArray) : IO ByteArray := do
  match alg with
  | .identity => pure payload
  | .gzip => gzipEncodePeer payload
  | .deflate => deflateEncodePeer payload
  | .snappy => pure (snappyEncodeLiteral payload)

def decompressIO (alg : Algorithm) (payload : ByteArray)
    (maxOut : Nat := 4 * 1024 * 1024) : IO (Except String ByteArray) := do
  match alg with
  | .identity =>
    if payload.size > maxOut then pure (.error "decompressed message too large")
    else pure (.ok payload)
  | .gzip => gzipDecodePeer payload maxOut
  | .deflate => deflateDecodePeer payload maxOut
  | .snappy =>
    match snappyDecodeLiteral payload with
    | .error e => pure (.error e)
    | .ok out =>
      if out.size > maxOut then pure (.error "decompressed message too large")
      else pure (.ok out)

private def trimAsciiSpaces (s : String) : String :=
  let cs := s.toList.dropWhile (fun c => c == ' ' || c == '\t')
  let cs := (cs.reverse.dropWhile (fun c => c == ' ' || c == '\t')).reverse
  String.ofList cs

/-- Negotiate an outbound algorithm from a peer's advertised `grpc-accept-encoding`
    list, preferring gzip > deflate > snappy > identity. -/
def negotiate (acceptEncoding : String) : Algorithm :=
  let tokens := acceptEncoding.splitOn "," |>.map trimAsciiSpaces
  if tokens.any (· == "gzip") then .gzip
  else if tokens.any (· == "deflate") then .deflate
  else if tokens.any (· == "snappy") then .snappy
  else .identity

end Grpc.Compression
