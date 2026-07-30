/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice

namespace Hpack

/-- Static table entry (RFC 7541 Appendix A). Indices are 1-based. -/
structure StaticEntry where
  name : ByteArray
  value : ByteArray
  deriving Inhabited

private def ascii (s : String) : ByteArray :=
  ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray

/-- RFC 7541 static table (61 entries). -/
def staticTable : Array StaticEntry := #[
  ⟨ascii ":authority", ByteArray.empty⟩,
  ⟨ascii ":method", ascii "GET"⟩,
  ⟨ascii ":method", ascii "POST"⟩,
  ⟨ascii ":path", ascii "/"⟩,
  ⟨ascii ":path", ascii "/index.html"⟩,
  ⟨ascii ":scheme", ascii "http"⟩,
  ⟨ascii ":scheme", ascii "https"⟩,
  ⟨ascii ":status", ascii "200"⟩,
  ⟨ascii ":status", ascii "204"⟩,
  ⟨ascii ":status", ascii "206"⟩,
  ⟨ascii ":status", ascii "304"⟩,
  ⟨ascii ":status", ascii "400"⟩,
  ⟨ascii ":status", ascii "404"⟩,
  ⟨ascii ":status", ascii "500"⟩,
  ⟨ascii "accept-charset", ByteArray.empty⟩,
  ⟨ascii "accept-encoding", ascii "gzip, deflate"⟩,
  ⟨ascii "accept-language", ByteArray.empty⟩,
  ⟨ascii "accept-ranges", ByteArray.empty⟩,
  ⟨ascii "accept", ByteArray.empty⟩,
  ⟨ascii "access-control-allow-origin", ByteArray.empty⟩,
  ⟨ascii "age", ByteArray.empty⟩,
  ⟨ascii "allow", ByteArray.empty⟩,
  ⟨ascii "authorization", ByteArray.empty⟩,
  ⟨ascii "cache-control", ByteArray.empty⟩,
  ⟨ascii "content-disposition", ByteArray.empty⟩,
  ⟨ascii "content-encoding", ByteArray.empty⟩,
  ⟨ascii "content-language", ByteArray.empty⟩,
  ⟨ascii "content-length", ByteArray.empty⟩,
  ⟨ascii "content-location", ByteArray.empty⟩,
  ⟨ascii "content-range", ByteArray.empty⟩,
  ⟨ascii "content-type", ByteArray.empty⟩,
  ⟨ascii "cookie", ByteArray.empty⟩,
  ⟨ascii "date", ByteArray.empty⟩,
  ⟨ascii "etag", ByteArray.empty⟩,
  ⟨ascii "expect", ByteArray.empty⟩,
  ⟨ascii "expires", ByteArray.empty⟩,
  ⟨ascii "from", ByteArray.empty⟩,
  ⟨ascii "host", ByteArray.empty⟩,
  ⟨ascii "if-match", ByteArray.empty⟩,
  ⟨ascii "if-modified-since", ByteArray.empty⟩,
  ⟨ascii "if-none-match", ByteArray.empty⟩,
  ⟨ascii "if-range", ByteArray.empty⟩,
  ⟨ascii "if-unmodified-since", ByteArray.empty⟩,
  ⟨ascii "last-modified", ByteArray.empty⟩,
  ⟨ascii "link", ByteArray.empty⟩,
  ⟨ascii "location", ByteArray.empty⟩,
  ⟨ascii "max-forwards", ByteArray.empty⟩,
  ⟨ascii "proxy-authenticate", ByteArray.empty⟩,
  ⟨ascii "proxy-authorization", ByteArray.empty⟩,
  ⟨ascii "range", ByteArray.empty⟩,
  ⟨ascii "referer", ByteArray.empty⟩,
  ⟨ascii "refresh", ByteArray.empty⟩,
  ⟨ascii "retry-after", ByteArray.empty⟩,
  ⟨ascii "server", ByteArray.empty⟩,
  ⟨ascii "set-cookie", ByteArray.empty⟩,
  ⟨ascii "strict-transport-security", ByteArray.empty⟩,
  ⟨ascii "transfer-encoding", ByteArray.empty⟩,
  ⟨ascii "user-agent", ByteArray.empty⟩,
  ⟨ascii "vary", ByteArray.empty⟩,
  ⟨ascii "via", ByteArray.empty⟩,
  ⟨ascii "www-authenticate", ByteArray.empty⟩
]

/-- 1-based static lookup. -/
def staticGet? (idx : Nat) : Option StaticEntry :=
  if idx == 0 ∨ idx > staticTable.size then none
  else some staticTable[idx - 1]!

/-- Find static index for exact name/value (1-based), preferring value match. -/
def findStaticExact (name value : ByteArray) : Option Nat :=
  Id.run do
    for i in [:staticTable.size] do
      let e : StaticEntry := staticTable[i]!
      if e.name == name && e.value == value then
        return some (i + 1)
    return none

/-- Find static index for name only (1-based). -/
def findStaticName (name : ByteArray) : Option Nat :=
  Id.run do
    for i in [:staticTable.size] do
      let e : StaticEntry := staticTable[i]!
      if e.name == name then
        return some (i + 1)
    return none

end Hpack
