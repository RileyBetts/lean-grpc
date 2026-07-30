/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Grpc.Resolver

namespace Grpc.Tls

/-- TLS configuration for ALPN `h2`. OpenSSL C bridge lives in `native/tls_bridge.c`
    (Lake may link it in a future revision). Today `connectH2` uses the insecure
    fallback only when `LEAN_GRPC_TLS_INSECURE_FALLBACK=1`; otherwise it errors and
    documents the Envoy/Caddy sidecar pattern. -/
structure Config where
  certPath : Option System.FilePath := none
  keyPath : Option System.FilePath := none
  caPath : Option System.FilePath := none
  alpn : Array String := #["h2"]
  serverName : Option String := none
  deriving Inhabited

def envoySidecarNotes : String :=
  "Terminate TLS at Envoy/Caddy with alpn_protocols: [h2], cluster to 127.0.0.1:<lean-h2c-port>."

/-- Connect with TLS+ALPN `h2`.
    - `LEAN_GRPC_TLS_PROXY=host:port` — connect h2c to a local OpenSSL ALPN proxy
      (`native/tls_proxy` / client forwarder) that terminates TLS to the real peer.
    - `LEAN_GRPC_TLS_INSECURE_FALLBACK=1` — plain h2c (dev only).
    - Otherwise error with sidecar / proxy instructions. -/
def connectH2 (host : String) (port : UInt16) (_cfg : Config := {}) : IO H2.ClientConn := do
  if let some proxy := ← IO.getEnv "LEAN_GRPC_TLS_PROXY" then
    let addr ← IO.ofExcept (Resolver.parseTarget proxy)
    IO.eprintln s!"Tls.connectH2 via LEAN_GRPC_TLS_PROXY={proxy} (ALPN terminated externally)"
    return (← H2.Client.connectH2c addr.host addr.port)
  match ← IO.getEnv "LEAN_GRPC_TLS_INSECURE_FALLBACK" with
  | some "1" =>
    IO.eprintln "WARN: LEAN_GRPC_TLS_INSECURE_FALLBACK=1 → h2c (no TLS)"
    H2.Client.connectH2c host port
  | _ =>
    throw (IO.userError
      s!"Grpc.Tls.connectH2: run native/tls_proxy (see scripts/interop-tls-go-lean.sh), \
set LEAN_GRPC_TLS_PROXY, or LEAN_GRPC_TLS_INSECURE_FALLBACK=1. Sidecar: {envoySidecarNotes}")

def serveH2 (_cfg : Config) (h2cfg : H2.ServerConfig) (handler : H2.StreamHandler) : IO Unit := do
  -- Application serves h2c; terminate TLS with native/tls_proxy or Envoy in front.
  match ← IO.getEnv "LEAN_GRPC_TLS_INSECURE_FALLBACK" with
  | some "1" => H2.Server.listen h2cfg handler
  | _ =>
    IO.eprintln s!"Tls.serveH2: serving h2c on {h2cfg.host}:{h2cfg.port}; put tls_proxy/Envoy in front for ALPN h2"
    H2.Server.listen h2cfg handler

end Grpc.Tls
