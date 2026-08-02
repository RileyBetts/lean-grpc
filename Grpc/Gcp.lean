/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Credentials
import Grpc.Metadata
import Grpc.Xds
import Grpc.Adc

namespace Grpc.Gcp

/-- Remaining live-GCP-only surfaces (ALTS / GCE channel creds). -/

inductive AllowlistCase where
  | computeEngineChannelCredentials
  | alts
  deriving BEq, Repr, Inhabited

def allowlistReason : AllowlistCase → String
  | .computeEngineChannelCredentials => "requires GCE + ALTS/TLS channel creds combo"
  | .alts => "ALTS is GCP-only transport security"

/-- Still needs a live GCP transport environment. -/
def deferredCases : Array AllowlistCase :=
  #[.computeEngineChannelCredentials, .alts]

/-- ADC call credentials: real Bearer via SA JSON or GCE metadata (see `Grpc.Adc`). -/
def googleDefaultCallCredentials : Credentials.CallCredentials :=
  Adc.callCredentials

/-- Compute-engine call credentials (metadata server token). -/
def computeEngineCallCredentials : Credentials.CallCredentials where
  apply := fun md => do
    Adc.clearCache
    -- Force metadata path even if GOOGLE_APPLICATION_CREDENTIALS is set.
    let saved ← IO.getEnv "GOOGLE_APPLICATION_CREDENTIALS"
    match saved with
    | some _ =>
      -- Temporarily unset is not portable; call metadata fetch directly.
      let tok ← Adc.fetchGceMetadataToken
      pure (Metadata.add md "authorization" s!"Bearer {tok}")
    | none =>
      let tok ← Adc.fetchGceMetadataToken
      pure (Metadata.add md "authorization" s!"Bearer {tok}")

/-- xDS target parse (static bootstrap resolve via `Grpc.Xds`). -/
def parseXdsTarget (target : String) : Except String String :=
  if "xds:///".isPrefixOf target then
    .ok (target.drop "xds:///".length).toString
  else
    .error "not an xds:/// target"

/-- ALTS channel creds stub — always errors outside GCP. -/
def altsDial (_target : String) : IO Unit :=
  throw (IO.userError "ALTS requires GCP; see Grpc.Gcp.deferredCases")

end Grpc.Gcp
