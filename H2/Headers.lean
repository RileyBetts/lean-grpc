/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Hpack

namespace H2

private def asciiLower (b : UInt8) : UInt8 :=
  if b ≥ 65 && b ≤ 90 then b + 32 else b

private def bytesEqAscii (b : ByteArray) (s : String) : Bool :=
  let want := ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray
  b == want

private def hasUpper (name : ByteArray) : Bool :=
  Id.run do
    for i in [:name.size] do
      let c := name.get! i
      if c ≥ 65 && c ≤ 90 then return true
    return false

private def isPseudo (name : ByteArray) : Bool :=
  name.size > 0 && name.get! 0 == ':'.toNat.toUInt8

/-- Validate request headers per RFC 9113 §8.1. Return error message if invalid. -/
def validateRequestHeaders (headers : Array Hpack.HeaderField) (isTrailer : Bool) :
    Option String :=
  Id.run do
    let mut method := false
    let mut scheme := false
    let mut path := false
    let mut pathEmpty := false
    let mut seenRegular := false
    let mut contentLength : Option Nat := none
    for h in headers do
      if hasUpper h.name then return some "uppercase header name"
      if isPseudo h.name then
        if isTrailer then return some "pseudo in trailer"
        if seenRegular then return some "pseudo after regular"
        if bytesEqAscii h.name ":method" then
          if method then return some "dup :method"
          method := true
        else if bytesEqAscii h.name ":scheme" then
          if scheme then return some "dup :scheme"
          scheme := true
        else if bytesEqAscii h.name ":path" then
          if path then return some "dup :path"
          path := true
          pathEmpty := h.value.isEmpty
        else if bytesEqAscii h.name ":authority" then
          pure ()
        else
          return some "unknown pseudo"
      else
        seenRegular := true
        if bytesEqAscii h.name "connection" || bytesEqAscii h.name "keep-alive" ||
            bytesEqAscii h.name "proxy-connection" || bytesEqAscii h.name "transfer-encoding" ||
            bytesEqAscii h.name "upgrade" then
          return some "connection-specific"
        if bytesEqAscii h.name "te" then
          if !(bytesEqAscii h.value "trailers") then return some "bad te"
        if bytesEqAscii h.name "content-length" then
          let s := String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat))
          match s.toNat? with
          | some n => contentLength := some n
          | none => return some "bad content-length"
    if !isTrailer then
      if !method then return some "missing :method"
      if !scheme then return some "missing :scheme"
      if !path then return some "missing :path"
      if pathEmpty then return some "empty :path"
    return none

def expectedContentLength (headers : Array Hpack.HeaderField) : Option Nat :=
  Id.run do
    for h in headers do
      if bytesEqAscii h.name "content-length" then
        let s := String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat))
        return s.toNat?
    return none

end H2
