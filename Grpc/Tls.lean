/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Grpc.Resolver
import Grpc.Native.Tls

namespace Grpc.Tls

/-- TLS configuration for ALPN `h2`. In-process OpenSSL via `Grpc.Native.Tls`. -/
structure Config where
  certPath : Option System.FilePath := none
  keyPath : Option System.FilePath := none
  caPath : Option System.FilePath := none
  alpn : Array String := #["h2"]
  serverName : Option String := none
  deriving Inhabited

def envoySidecarNotes : String :=
  "Optional: terminate TLS at Envoy/Caddy with alpn_protocols: [h2], cluster to 127.0.0.1:<lean-h2c-port>."

/-- Connect with TLS+ALPN `h2`.
    Priority:
    1. `LEAN_GRPC_TLS_PROXY` — h2c to local sidecar/proxy (legacy).
    2. In-process OpenSSL (`caPath` / peer verify optional).
    3. `LEAN_GRPC_TLS_INSECURE_FALLBACK=1` — plain h2c (dev only). -/
def connectH2 (host : String) (port : UInt16) (cfg : Config := {}) : IO H2.ClientConn := do
  if let some proxy := ← IO.getEnv "LEAN_GRPC_TLS_PROXY" then
    let addr ← IO.ofExcept (Resolver.parseTarget proxy)
    IO.eprintln s!"Tls.connectH2 via LEAN_GRPC_TLS_PROXY={proxy} (ALPN terminated externally)"
    return (← H2.Client.connectH2c addr.host addr.port)
  match ← IO.getEnv "LEAN_GRPC_TLS_INSECURE_FALLBACK" with
  | some "1" =>
    IO.eprintln "WARN: LEAN_GRPC_TLS_INSECURE_FALLBACK=1 → h2c (no TLS)"
    H2.Client.connectH2c host port
  | _ =>
    let ca := (cfg.caPath.map (·.toString)).getD ""
    let sni := cfg.serverName.getD host
    let conn ← Grpc.Native.Tls.dial host port ca sni
    H2.Client.connectTransport (Grpc.Native.Tls.transport conn)

/-- Serve with in-process TLS+ALPN when cert/key are set; otherwise h2c (+ optional sidecar). -/
partial def serveH2 (cfg : Config) (h2cfg : H2.ServerConfig) (handler : H2.StreamHandler) : IO Unit := do
  match cfg.certPath, cfg.keyPath with
  | some cert, some key =>
    let listener ← Grpc.Native.Tls.listen h2cfg.port cert.toString key.toString
    IO.println s!"H2 TLS+ALPN listening on {h2cfg.host}:{h2cfg.port}"
    while true do
      let conn ← Grpc.Native.Tls.accept listener
      discard <| IO.asTask (prio := .dedicated) do
        try
          H2.serveTransport (Grpc.Native.Tls.transport conn) handler
        catch e =>
          IO.eprintln s!"tls conn error: {e}"
  | _, _ =>
    match ← IO.getEnv "LEAN_GRPC_TLS_INSECURE_FALLBACK" with
    | some "1" => H2.Server.listen h2cfg handler
    | _ =>
      IO.eprintln s!"Tls.serveH2: serving h2c on {h2cfg.host}:{h2cfg.port}; set certPath/keyPath for in-process TLS, or use sidecar. {envoySidecarNotes}"
      H2.Server.listen h2cfg handler

end Grpc.Tls
