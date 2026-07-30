/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Metadata
import Grpc.Tls

namespace Grpc.Credentials

/-- Channel-level credentials. -/
inductive ChannelCredentials where
  | insecure
  | tls (cfg : Tls.Config)
  deriving Inhabited

/-- Per-RPC / call credentials that inject metadata. -/
structure CallCredentials where
  apply : Metadata → IO Metadata

def CallCredentials.accessToken (token : String) : CallCredentials where
  apply := fun md => pure (Metadata.add md "authorization" s!"Bearer {token}")

def CallCredentials.composite (a b : CallCredentials) : CallCredentials where
  apply := fun md => do
    let md ← a.apply md
    b.apply md

/-- JWT call creds: places a pre-signed JWT as Bearer token (fixture-friendly). -/
def CallCredentials.jwt (jwt : String) : CallCredentials :=
  accessToken jwt

/-- Dial options combining channel + optional call credentials. -/
structure DialOptions where
  channel : ChannelCredentials := .insecure
  call : Option CallCredentials := none
  authority : Option String := none
  deriving Inhabited

end Grpc.Credentials
