/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Lean.Data.Json
import Grpc.Jwt
import Grpc.Native.Tls
import Grpc.Credentials
import Grpc.Metadata

open Lean (Json)

namespace Grpc.Adc

/-- Cached Bearer token + wall-clock expiry (mono ms). -/
structure CachedToken where
  accessToken : String
  expireAtMs : Nat
  deriving Inhabited

private initialize cacheRef : IO.Ref (Option CachedToken) ← IO.mkRef none

/-- Require `LEAN_GRPC_ALLOW_ADC_OVERRIDE=1` for env redirects / insecure token HTTP. -/
private def adcOverrideAllowed : IO Bool := do
  match ← IO.getEnv "LEAN_GRPC_ALLOW_ADC_OVERRIDE" with
  | some "1" => pure true
  | _ => pure false

private def requireAdcOverride (what : String) : IO Unit := do
  unless ← adcOverrideAllowed do
    throw (IO.userError s!"ADC {what} requires LEAN_GRPC_ALLOW_ADC_OVERRIDE=1 (test/CI only)")

/-- JSON string field via `Lean.Data.Json`. -/
def jsonStringField (json key : String) : Option String :=
  match Json.parse json with
  | .error _ => none
  | .ok j =>
    match j.getObjValAs? String key with
    | .ok s => some s
    | .error _ => none

/-- Extract numeric `expires_in` (seconds). -/
def jsonNatField (json key : String) : Option Nat :=
  match Json.parse json with
  | .error _ => none
  | .ok j =>
    match j.getObjValAs? Nat key with
    | .ok n => some n
    | .error _ =>
      match j.getObjValAs? Int key with
      | .ok n => some n.toNat
      | .error _ => none

/-- Escape a string for embedding in a JSON object value. -/
private def jsonEscape (s : String) : String :=
  Id.run do
    let mut out := ""
    for c in s.toList do
      out :=
        match c with
        | '\\' => out ++ "\\\\"
        | '"' => out ++ "\\\""
        | '\n' => out ++ "\\n"
        | '\r' => out ++ "\\r"
        | '\t' => out ++ "\\t"
        | _ => out.push c
    return out

/-- Allowed token URI hosts for SA JWT exchange. -/
def tokenUriHostAllowed (host : String) : Bool :=
  host == "oauth2.googleapis.com" || host == "www.googleapis.com" ||
    host.endsWith ".googleapis.com"

/-- Parse `host:port` (default port 80). -/
def parseHostPort (s : String) (defaultPort : UInt16 := 80) : String × UInt16 :=
  match s.splitOn ":" with
  | [h, p] => (h, (p.toNat?.getD defaultPort.toNat).toUInt16)
  | _ => (s, defaultPort)

/-- GCE metadata token fetch.
    Override host with `LEAN_GRPC_GCE_METADATA=host:port` (requires ADC override). -/
def fetchGceMetadataToken (scope : String := "https://www.googleapis.com/auth/cloud-platform") :
    IO String := do
  let target ←
    match ← IO.getEnv "LEAN_GRPC_GCE_METADATA" with
    | some t =>
      requireAdcOverride "GCE_METADATA override"
      pure t
    | none => pure "metadata.google.internal:80"
  let (host, port) := parseHostPort target 80
  let path :=
    s!"/computeMetadata/v1/instance/service-accounts/default/token?scopes={scope}"
  -- Trailing CRLF required: native helper validates header lines and ends the block.
  let hdrs := "Metadata-Flavor: Google\r\n"
  let body ← Grpc.Native.Tls.httpGet host port path hdrs
  match jsonStringField body "access_token" with
  | some t => pure t
  | none => throw (IO.userError "GCE metadata: no access_token in response")

/-- Build RS256 JWT assertion for a service account. -/
def serviceAccountAssertion (clientEmail privateKeyPem tokenUri : String)
    (scope : String := "https://www.googleapis.com/auth/cloud-platform") : IO String := do
  let now ← IO.monoMsNow
  let iat := now / 1000
  let exp := iat + 3600
  let hdr := Jwt.base64UrlEncode "{\"alg\":\"RS256\",\"typ\":\"JWT\"}".toUTF8
  let payload :=
    "{\"iss\":\"" ++ jsonEscape clientEmail ++ "\",\"scope\":\"" ++ jsonEscape scope ++
    "\",\"aud\":\"" ++ jsonEscape tokenUri ++ "\",\"exp\":" ++ toString exp ++
    ",\"iat\":" ++ toString iat ++ "}"
  let claimSet := Jwt.base64UrlEncode payload.toUTF8
  let signingInput := s!"{hdr}.{claimSet}"
  let sig ← Grpc.Native.Tls.rsaSignSha256 privateKeyPem signingInput.toUTF8
  let sigB64 := Jwt.base64UrlEncode sig
  return s!"{signingInput}.{sigB64}"

/-- Exchange JWT assertion at token URI (HTTPS).
    Insecure HTTP mock / host override require `LEAN_GRPC_ALLOW_ADC_OVERRIDE=1`. -/
def exchangeJwtForToken (tokenUri assertion : String) : IO String := do
  let bodyStr :=
    "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=" ++ assertion
  let body := bodyStr.toUTF8
  match ← IO.getEnv "LEAN_GRPC_TOKEN_INSECURE" with
  | some "1" =>
    requireAdcOverride "TOKEN_INSECURE"
    let target := (← IO.getEnv "LEAN_GRPC_TOKEN_HOST").getD "127.0.0.1:8080"
    let (host, port) := parseHostPort target 8080
    let path := (← IO.getEnv "LEAN_GRPC_TOKEN_PATH").getD "/token"
    let resp ← Grpc.Native.Tls.httpPost host port path bodyStr.toUTF8
      "application/x-www-form-urlencoded"
    match jsonStringField resp "access_token" with
    | some t => pure t
    | none => throw (IO.userError "token mock: no access_token in response")
  | _ =>
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
    let (h, p) ←
      match override with
      | some t =>
        requireAdcOverride "TOKEN_HOST override"
        pure (parseHostPort t 443)
      | none =>
        unless tokenUriHostAllowed host do
          throw (IO.userError s!"token_uri host not allowlisted: {host}")
        pure (host, (443 : UInt16))
    let resp ← Grpc.Native.Tls.httpsPost h p path body "application/x-www-form-urlencoded" "" false
    match jsonStringField resp "access_token" with
    | some t => pure t
    | none => throw (IO.userError "token exchange: no access_token in response")

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
  let expiresIn := 3600
  cacheRef.set (some { accessToken := tok, expireAtMs := now + expiresIn * 1000 })
  return tok

/-- Per-RPC call credentials that inject `authorization: Bearer <adc>`. -/
def callCredentials : Credentials.CallCredentials where
  apply := fun md => do
    let tok ← accessToken
    pure (Metadata.add md "authorization" s!"Bearer {tok}")

/-- Clear cached token (tests). -/
def clearCache : IO Unit :=
  cacheRef.set none

/-- Dial options for calling Google APIs with Application Default
    Credentials: TLS channel credentials (system trust store when `caPath`
    is none; peer+hostname verified) composed with an ADC-derived per-RPC
    Bearer token. Lives here rather than `Grpc.Credentials` to avoid a
    Credentials → Adc → Credentials import cycle. -/
def dialOptions (caPath : Option System.FilePath := none) (serverName : Option String := none) :
    Credentials.DialOptions :=
  { channel := .tls { caPath, serverName }
    call := some callCredentials }

end Grpc.Adc
