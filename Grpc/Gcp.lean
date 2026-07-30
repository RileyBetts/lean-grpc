/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Credentials
import Grpc.Metadata

namespace Grpc.Gcp

/-- Phase 10 surfaces: GCP-only credentials and control-plane features.
    Stubbed for API shape; live GCP CI is allowlisted in docs/conformance.md. -/

inductive AllowlistCase where
  | computeEngineCreds
  | googleDefaultCredentials
  | computeEngineChannelCredentials
  | alts
  | orcaPerRpc
  | orcaOob
  | xdsResolver
  deriving BEq, Repr, Inhabited

def allowlistReason : AllowlistCase → String
  | .computeEngineCreds => "requires GCE metadata server / live GCP"
  | .googleDefaultCredentials => "requires Application Default Credentials"
  | .computeEngineChannelCredentials => "requires GCE + TLS channel creds"
  | .alts => "ALTS is GCP-only transport security"
  | .orcaPerRpc => "ORCA per-RPC load reporting not yet implemented"
  | .orcaOob => "ORCA OOB not yet implemented"
  | .xdsResolver => "xDS control-plane subset deferred; DNS/pick_first/RR cover app RPCs"

/-- Documented non-goals / deferred until GCP-gated CI. -/
def deferredCases : Array AllowlistCase :=
  #[.computeEngineCreds, .googleDefaultCredentials, .computeEngineChannelCredentials,
    .alts, .orcaPerRpc, .orcaOob, .xdsResolver]

/-- Stub: google-default call credentials (injects sentinel when ADC path is set). -/
def googleDefaultCallCredentials : Credentials.CallCredentials where
  apply := fun md => do
    match ← IO.getEnv "GOOGLE_APPLICATION_CREDENTIALS" with
    | some _ => pure (Metadata.add md "x-goog-lean-grpc-adc" "1")
    | none => pure md

/-- Minimal xDS target parse (`xds:///name`). -/
def parseXdsTarget (target : String) : Except String String :=
  if "xds:///".isPrefixOf target then
    .ok (target.drop "xds:///".length).toString
  else
    .error "not an xds:/// target"

end Grpc.Gcp
