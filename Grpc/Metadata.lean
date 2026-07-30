/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Hpack
import Grpc.Status

namespace Grpc

structure Metadata where
  entries : Array Hpack.HeaderField := #[]
  deriving Inhabited

namespace Metadata

def empty : Metadata := {}

def ascii (s : String) : ByteArray :=
  ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray

def add (m : Metadata) (name value : String) : Metadata :=
  { m with entries := m.entries.push ⟨ascii name, ascii value⟩ }

def get? (m : Metadata) (name : String) : Option String :=
  let n := ascii name
  Id.run do
    for e in m.entries do
      if e.name == n then
        return some (String.ofList (e.value.toList.map (fun b => Char.ofNat b.toNat)))
    return none

private def hexDigit (n : Nat) : Char :=
  let hex := #['0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F']
  hex[n]!

/-- Percent-encode UTF-8 bytes for grpc-message (RFC 3986 unreserved). -/
def percentEncode (s : String) : String :=
  Id.run do
    let bytes := s.toUTF8
    let mut out := ""
    for i in [:bytes.size] do
      let n := (bytes.get! i).toNat
      let c := Char.ofNat n
      let ok :=
        n < 128 &&
          (('a' ≤ c && c ≤ 'z') || ('A' ≤ c && c ≤ 'Z') || ('0' ≤ c && c ≤ '9') ||
            c == '-' || c == '_' || c == '.' || c == '~')
      if ok then
        out := out.push c
      else
        out := out ++ "%" ++ String.singleton (hexDigit (n / 16))
          ++ String.singleton (hexDigit (n % 16))
    return out

private def hexVal (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else none

def percentDecode (s : String) : String :=
  Id.run do
    let cs := s.toList.toArray
    let mut bytes := ByteArray.empty
    let mut i := 0
    while i < cs.size do
      let c := cs[i]!
      if c == '%' && i + 2 < cs.size then
        match hexVal cs[i+1]!, hexVal cs[i+2]! with
        | some hi, some lo =>
          bytes := bytes.push (hi * 16 + lo).toUInt8
          i := i + 3
        | _, _ =>
          bytes := bytes.push c.toNat.toUInt8
          i := i + 1
      else
        bytes := bytes.push c.toNat.toUInt8
        i := i + 1
    match String.fromUTF8? bytes with
    | some str => str
    | none => String.ofList (bytes.toList.map (fun b => Char.ofNat b.toNat))

private def b64Alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

/-- Base64 (standard) encode for `-bin` metadata. -/
def base64Encode (data : ByteArray) : String :=
  Id.run do
    let mut out := ""
    let mut i := 0
    while i < data.size do
      let b0 := data.get! i |>.toNat
      let b1 := if i + 1 < data.size then data.get! (i + 1) |>.toNat else 0
      let b2 := if i + 2 < data.size then data.get! (i + 2) |>.toNat else 0
      let n := (b0 <<< 16) ||| (b1 <<< 8) ||| b2
      out := out.push b64Alphabet[((n >>> 18) &&& 63)]!
      out := out.push b64Alphabet[((n >>> 12) &&& 63)]!
      if i + 1 < data.size then
        out := out.push b64Alphabet[((n >>> 6) &&& 63)]!
      else
        out := out.push '='
      if i + 2 < data.size then
        out := out.push b64Alphabet[n &&& 63]!
      else
        out := out.push '='
      i := i + 3
    return out

private def b64Val (c : Char) : Option Nat :=
  if 'A' ≤ c && c ≤ 'Z' then some (c.toNat - 'A'.toNat)
  else if 'a' ≤ c && c ≤ 'z' then some (c.toNat - 'a'.toNat + 26)
  else if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat + 52)
  else if c == '+' then some 62
  else if c == '/' then some 63
  else none

def base64Decode (s : String) : Except String ByteArray := do
  let chars := s.toList.filter (· != '=')
  if chars.length % 4 == 1 then throw "bad base64"
  let mut out := ByteArray.empty
  let mut i := 0
  let arr := chars.toArray
  while i < arr.size do
    let v0 ← b64Val arr[i]! |>.elim (throw "bad b64") pure
    let v1 ← if i + 1 < arr.size then b64Val arr[i+1]! |>.elim (throw "bad b64") pure else pure 0
    let v2 ← if i + 2 < arr.size then b64Val arr[i+2]! |>.elim (throw "bad b64") pure else pure 0
    let v3 ← if i + 3 < arr.size then b64Val arr[i+3]! |>.elim (throw "bad b64") pure else pure 0
    let n := (v0 <<< 18) ||| (v1 <<< 12) ||| (v2 <<< 6) ||| v3
    out := out.push ((n >>> 16) &&& 255).toUInt8
    if i + 2 < arr.size then out := out.push ((n >>> 8) &&& 255).toUInt8
    if i + 3 < arr.size then out := out.push (n &&& 255).toUInt8
    i := i + 4
  return out

def addBin (m : Metadata) (name : String) (value : ByteArray) : Metadata :=
  let n := if name.endsWith "-bin" then name else name ++ "-bin"
  add m n (base64Encode value)

def contentTypeGrpc : Hpack.HeaderField :=
  ⟨ascii "content-type", ascii "application/grpc+proto"⟩

def path (service method : String) : Hpack.HeaderField :=
  ⟨ascii ":path", ascii s!"/{service}/{method}"⟩

def methodPost : Hpack.HeaderField := ⟨ascii ":method", ascii "POST"⟩
def schemeHttp : Hpack.HeaderField := ⟨ascii ":scheme", ascii "http"⟩
def teTrailers : Hpack.HeaderField := ⟨ascii "te", ascii "trailers"⟩

def timeout (duration : String) : Hpack.HeaderField :=
  ⟨ascii "grpc-timeout", ascii duration⟩

def grpcEncoding (name : String) : Hpack.HeaderField :=
  ⟨ascii "grpc-encoding", ascii name⟩

def grpcAcceptEncoding (names : String := "identity,gzip") : Hpack.HeaderField :=
  ⟨ascii "grpc-accept-encoding", ascii names⟩

/-- Parse gRPC timeout like `10S`, `100m`, `5M`, `1H`, `100u`, `100n` into milliseconds. -/
def parseTimeoutMs (t : String) : Option Nat :=
  if t.isEmpty then none
  else
    let chars := t.toList
    match chars.reverse with
    | [] => none
    | unit :: restRev =>
      let numStr := String.ofList restRev.reverse
      match numStr.toNat? with
      | none => none
      | some n =>
        match unit with
        | 'H' => some (n * 3600 * 1000)
        | 'M' => some (n * 60 * 1000)
        | 'S' => some (n * 1000)
        | 'm' => some n
        | 'u' => some (if n == 0 then 0 else max 1 (n / 1000))
        | 'n' => some 0
        | _ => none

def statusHeaders (st : Status) : Array Hpack.HeaderField :=
  let base := #[⟨ascii "grpc-status", ascii (toString st.code.toUInt32)⟩]
  if st.message.isEmpty then base
  else base.push ⟨ascii "grpc-message", ascii (percentEncode st.message)⟩

def http200 : Array Hpack.HeaderField :=
  #[⟨ascii ":status", ascii "200"⟩, contentTypeGrpc]

def toFields (m : Metadata) : Array Hpack.HeaderField := m.entries

end Metadata
end Grpc
