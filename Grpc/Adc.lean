/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Jwt
import Grpc.Native.Tls
import Grpc.Credentials
import Grpc.Metadata

namespace Grpc.Adc

/-- Cached Bearer token + wall-clock expiry (mono ms). -/
structure CachedToken where
  accessToken : String
  expireAtMs : Nat
  deriving Inhabited

private initialize cacheRef : IO.Ref (Option CachedToken) ← IO.mkRef none

/-- Minimal JSON string field extract (`"key":"value"`). -/
def jsonStringField (json key : String) : Option String :=
  Jwt.claim json key

/-- Extract numeric `expires_in` (seconds). -/
def jsonNatField (json key : String) : Option Nat :=
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
        let mut num := ""
        while k < cs.size && cs[k]!.isDigit do
          num := num.push cs[k]!
          k := k + 1
        return num.toNat?
      i := i + 1
    return none

/-- Parse `host:port` (default port 80). -/
def parseHostPort (s : String) (defaultPort : UInt16 := 80) : String × UInt16 :=
  match s.splitOn ":" with
  | [h, p] => (h, (p.toNat?.getD defaultPort.toNat).toUInt16)
  | _ => (s, defaultPort)

/-- GCE metadata token fetch.
    Override host with `LEAN_GRPC_GCE_METADATA=host:port` (CI mock). -/
def fetchGceMetadataToken (scope : String := "https://www.googleapis.com/auth/cloud-platform") :
    IO String := do
  let target := (← IO.getEnv "LEAN_GRPC_GCE_METADATA").getD "metadata.google.internal:80"
  let (host, port) := parseHostPort target 80
  let path :=
    s!"/computeMetadata/v1/instance/service-accounts/default/token?scopes={scope}"
  let hdrs := "Metadata-Flavor: Google\r\n"
  let body ← Grpc.Native.Tls.httpGet host port path hdrs
  match jsonStringField body "access_token" with
  | some t => pure t
  | none => throw (IO.userError s!"GCE metadata: no access_token in `{body}`")

/-- Build RS256 JWT assertion for a service account. -/
def serviceAccountAssertion (clientEmail privateKeyPem tokenUri : String)
    (scope : String := "https://www.googleapis.com/auth/cloud-platform") : IO String := do
  let now ← IO.monoMsNow
  let iat := now / 1000
  let exp := iat + 3600
  let hdr := Jwt.base64UrlEncode "{\"alg\":\"RS256\",\"typ\":\"JWT\"}".toUTF8
  let payload :=
    "{\"iss\":\"" ++ clientEmail ++ "\",\"scope\":\"" ++ scope ++
    "\",\"aud\":\"" ++ tokenUri ++ "\",\"exp\":" ++ toString exp ++
    ",\"iat\":" ++ toString iat ++ "}"
  let claimSet := Jwt.base64UrlEncode payload.toUTF8
  let signingInput := s!"{hdr}.{claimSet}"
  let sig ← Grpc.Native.Tls.rsaSignSha256 privateKeyPem signingInput.toUTF8
  let sigB64 := Jwt.base64UrlEncode sig
  return s!"{signingInput}.{sigB64}"

/-- Exchange JWT assertion at token URI (HTTPS).
    Override with `LEAN_GRPC_TOKEN_HOST=host:port` + path from URI (CI mock uses HTTP via
    `LEAN_GRPC_TOKEN_INSECURE=1`). -/
def exchangeJwtForToken (tokenUri assertion : String) : IO String := do
  let bodyStr :=
    "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=" ++ assertion
  let body := bodyStr.toUTF8
  match ← IO.getEnv "LEAN_GRPC_TOKEN_INSECURE" with
  | some "1" =>
    let target := (← IO.getEnv "LEAN_GRPC_TOKEN_HOST").getD "127.0.0.1:8080"
    let (host, port) := parseHostPort target 8080
    let path := (← IO.getEnv "LEAN_GRPC_TOKEN_PATH").getD "/token"
    let resp ← Grpc.Native.Tls.httpPost host port path bodyStr.toUTF8
      "application/x-www-form-urlencoded"
    match jsonStringField resp "access_token" with
    | some t => pure t
    | none => throw (IO.userError s!"token mock: no access_token `{resp}`")
  | _ =>
    -- Parse https://oauth2.googleapis.com/token
    let host :=
      if "https://".isPrefixOf tokenUri then
        let rest := (tokenUri.drop "https://".length).toString
        (rest.splitOn "/").getD 0 "oauth2.googleapis.com"
      else "oauth2.googleapis.com"
    let path :=
      let rest :=
        if "https://".isPrefixOf tokenUri then
          (tokenUri.drop ("https://".length + host.length)).toString
        else "/token"
      if rest.isEmpty then "/token" else rest
    let override := ← IO.getEnv "LEAN_GRPC_TOKEN_HOST"
    let (h, p) :=
      match override with
      | some t => parseHostPort t 443
      | none => (host, (443 : UInt16))
    let resp ← Grpc.Native.Tls.httpsPost h p path body "application/x-www-form-urlencoded"
    match jsonStringField resp "access_token" with
    | some t => pure t
    | none => throw (IO.userError s!"token exchange: no access_token `{resp}`")

/-- Load SA JSON and obtain access token. -/
def fetchServiceAccountToken (jsonPath : System.FilePath) : IO String := do
  let text ← IO.FS.readFile jsonPath
  let email ←
    match jsonStringField text "client_email" with
    | some e => pure e
    | none => throw (IO.userError "SA JSON missing client_email")
  let key ←
    match jsonStringField text "private_key" with
    | some k =>
      -- JSON escapes newlines as \n
      pure (String.intercalate "\n" (k.splitOn "\\n"))
    | none => throw (IO.userError "SA JSON missing private_key")
  let tokenUri := (jsonStringField text "token_uri").getD "https://oauth2.googleapis.com/token"
  let assertion ← serviceAccountAssertion email key tokenUri
  exchangeJwtForToken tokenUri assertion

/-- Resolve ADC token: SA file → GCE metadata. Uses short-lived cache. -/
def accessToken : IO String := do
  let now ← IO.monoMsNow
  match ← cacheRef.get with
  | some c =>
    if now + 60000 < c.expireAtMs then return c.accessToken
  | none => pure ()
  let tok ←
    match ← IO.getEnv "GOOGLE_APPLICATION_CREDENTIALS" with
    | some path => fetchServiceAccountToken path
    | none => fetchGceMetadataToken
  let exp := now + 3000000 -- ~50 min default cache
  cacheRef.set (some { accessToken := tok, expireAtMs := exp })
  return tok

/-- Call credentials that attach a real `Authorization: Bearer` token. -/
def callCredentials : Credentials.CallCredentials where
  apply := fun md => do
    let tok ← accessToken
    pure (Metadata.add md "authorization" s!"Bearer {tok}")

/-- Clear cached token (tests). -/
def clearCache : IO Unit :=
  cacheRef.set none

end Grpc.Adc
