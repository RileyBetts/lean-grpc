/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Metadata

namespace Grpc.Jwt

/-- Base64url (JWT) alphabet encode without padding. -/
def base64UrlEncode (data : ByteArray) : String :=
  let s := Metadata.base64Encode data
  String.ofList (s.toList.filterMap fun c =>
    if c == '+' then some '-'
    else if c == '/' then some '_'
    else if c == '=' then none
    else some c)

def base64UrlDecode (s : String) : Except String ByteArray := do
  let mut norm := ""
  for c in s.toList do
    if c == '-' then norm := norm.push '+'
    else if c == '_' then norm := norm.push '/'
    else if c != '=' then norm := norm.push c
  while norm.length % 4 != 0 do
    norm := norm.push '='
  Metadata.base64Decode norm

private def splitDots (s : String) : Array String :=
  Id.run do
    let mut out : Array String := #[]
    let mut cur := ""
    for c in s.toList do
      if c == '.' then
        out := out.push cur
        cur := ""
      else
        cur := cur.push c
    out := out.push cur
    return out

/-- Unverified JWT payload JSON extract for fixture tests. -/
def payloadJson (jwt : String) : Except String String := do
  let parts := splitDots jwt
  if parts.size < 2 then throw "jwt parts"
  let bytes ← base64UrlDecode parts[1]!
  match String.fromUTF8? bytes with
  | some s => pure s
  | none => throw "jwt utf8"

/-- Pull `"email":"..."` or `"sub":"..."` from a minimal JSON object. -/
def claim (json key : String) : Option String :=
  Id.run do
    let needle := s!"\"{key}\""
    let ncs := needle.toList.toArray
    let cs := json.toList.toArray
    let mut i := 0
    while i + ncs.size ≤ cs.size do
      let mut ok := true
      for j in [:ncs.size] do
        if cs[i + j]! != ncs[j]! then ok := false
      if ok then
        let mut k := i + ncs.size
        while k < cs.size && (cs[k]! == ' ' || cs[k]! == ':' || cs[k]! == '\t') do
          k := k + 1
        if k < cs.size && cs[k]! == '"' then
          k := k + 1
          let mut out := ""
          while k < cs.size && cs[k]! != '"' do
            out := out.push cs[k]!
            k := k + 1
          return some out
      i := i + 1
    return none

/-- Build an unsigned (`alg:none`) JWT for local interop fixtures. -/
def fixtureUnsigned (email : String := "lean-test@example.com") : String :=
  let hdr := base64UrlEncode "{\"alg\":\"none\",\"typ\":\"JWT\"}".toUTF8
  let payloadJson := "{\"email\":\"" ++ email ++ "\",\"sub\":\"" ++ email ++ "\"}"
  let payload := base64UrlEncode payloadJson.toUTF8
  s!"{hdr}.{payload}."

/-- Username implied by Authorization bearer (JWT email/sub, else raw token). -/
def usernameFromAuthorization (authHeader : String) : String :=
  let token :=
    if "Bearer ".isPrefixOf authHeader then (authHeader.drop "Bearer ".length).toString
    else if "bearer ".isPrefixOf authHeader then (authHeader.drop "bearer ".length).toString
    else authHeader
  match payloadJson token with
  | .ok json =>
    match claim json "email" with
    | some e => e
    | none => (claim json "sub").getD token
  | .error _ => token

end Grpc.Jwt
