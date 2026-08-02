/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc

/-- ADC smoke: metadata token and SA JWT→token against local mock (env-configured). -/
def main (_args : List String) : IO Unit := do
  Grpc.Adc.clearCache
  -- 1) GCE metadata path
  let metaTok ← Grpc.Adc.fetchGceMetadataToken
  if metaTok != "meta-fixture-token" then
    throw (IO.userError s!"metadata token `{metaTok}`")
  IO.println "adc metadata OK"

  -- 2) SA JSON path (GOOGLE_APPLICATION_CREDENTIALS + insecure token mock)
  Grpc.Adc.clearCache
  match ← IO.getEnv "GOOGLE_APPLICATION_CREDENTIALS" with
  | none => throw (IO.userError "GOOGLE_APPLICATION_CREDENTIALS not set")
  | some path =>
    let tok ← Grpc.Adc.fetchServiceAccountToken path
    if tok != "sa-fixture-token" then
      throw (IO.userError s!"sa token `{tok}`")
  IO.println "adc service_account OK"

  -- 3) CallCredentials attach Bearer
  Grpc.Adc.clearCache
  let md ← Grpc.Gcp.googleDefaultCallCredentials.apply Grpc.Metadata.empty
  let fields := Grpc.Metadata.toFields md
  let mut ok := false
  for f in fields do
    let n := String.fromUTF8! f.name
    let v := String.fromUTF8! f.value
    if n == "authorization" && "Bearer ".isPrefixOf v then
      ok := true
  if !ok then throw (IO.userError "missing Bearer authorization")
  IO.println "adc call_credentials OK"
