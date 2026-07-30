/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2

namespace Grpc.Tls

/-- Phase 7 placeholder: pure-Lean TLS+ALPN `h2` is not available yet.
    Until a Lean TLS stack exists, terminate TLS externally (Envoy/Caddy/nginx)
    and speak h2c to the Lean process on localhost. -/
structure Config where
  certPath : Option System.FilePath := none
  keyPath : Option System.FilePath := none
  alpn : Array String := #["h2"]
  deriving Inhabited

inductive Error where
  | notImplemented (detail : String)
  deriving Inhabited

/-- Reserved API for future Lean TLS. -/
def connectH2 (host : String) (port : UInt16) (_cfg : Config := {}) : IO H2.ClientConn := do
  throw (IO.userError
    s!"Grpc.Tls.connectH2 not implemented (host={host}:{port}). Use Channel.connectH2c behind a TLS terminator.")

def serveH2 (_cfg : Config) (_h2cfg : H2.ServerConfig) (_handler : H2.StreamHandler) : IO Unit := do
  throw (IO.userError
    "Grpc.Tls.serveH2 not implemented. Use Server.serveH2c behind Envoy/Caddy with ALPN h2.")

/-- Documented sidecar pattern for production TLS. -/
def envoySidecarNotes : String :=
  "Terminate TLS at Envoy/Caddy with alpn_protocols: [h2], cluster to 127.0.0.1:<lean-h2c-port>."

end Grpc.Tls
