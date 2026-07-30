/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Credentials
import Grpc.Metadata
import Grpc.Xds

namespace Grpc.Gcp

/-- Phase 10: GCP-only / control-plane surfaces.
    Fixture-local pieces are implemented; live GCE/ALTS remain allowlisted. -/

inductive AllowlistCase where
  | computeEngineCreds
  | googleDefaultCredentials
  | computeEngineChannelCredentials
  | alts
  deriving BEq, Repr, Inhabited

def allowlistReason : AllowlistCase → String
  | .computeEngineCreds => "requires GCE metadata server / live GCP"
  | .googleDefaultCredentials => "requires live Application Default Credentials against Google APIs"
  | .computeEngineChannelCredentials => "requires GCE + TLS channel creds"
  | .alts => "ALTS is GCP-only transport security"

/-- Still needs a live GCP environment (not fixture-testable here). -/
def deferredCases : Array AllowlistCase :=
  #[.computeEngineCreds, .googleDefaultCredentials, .computeEngineChannelCredentials, .alts]

/-- ADC call credentials: fixture path injects sentinel; otherwise no-op. -/
def googleDefaultCallCredentials : Credentials.CallCredentials where
  apply := fun md => do
    match ← IO.getEnv "GOOGLE_APPLICATION_CREDENTIALS" with
    | some _ => pure (Metadata.add md "x-goog-lean-grpc-adc" "1")
    | none => pure md

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
