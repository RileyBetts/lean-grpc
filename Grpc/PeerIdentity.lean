/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Metadata

namespace Grpc

/-- Verified TLS peer certificate identity.
    Fields come **only** from the peer cert on the TLS connection (via OpenSSL),
    never from client-supplied gRPC metadata.

    `subjectDn` uses OpenSSL RFC 2253 one-line form (`XN_FLAG_RFC2253`). -/
structure PeerIdentity where
  subjectDn : String
  commonName : String
  dnsSans : Array String
  uriSans : Array String
  fingerprintSha256 : String
  serial : String := ""
  deriving Inhabited, Repr

/-- Per-RPC server context for unary handlers registered with `registerWithContext`.

    * `peerIdentity` — `some` after mTLS when a client cert was presented and verified;
      `none` on h2c, TLS without client cert, or when no peer cert is available.
    * `metadata` — inbound request headers (HTTP/2 lowercased names; excludes `:pseudo`).
    * `methodPath` — e.g. `/svc/Method`.
    * `mtlsRequired` — `true` when the listener was configured with `clientCaPath`. -/
structure ServerCallContext where
  peerIdentity : Option PeerIdentity := none
  metadata : Metadata := {}
  methodPath : String := ""
  mtlsRequired : Bool := false
  deriving Inhabited

end Grpc
