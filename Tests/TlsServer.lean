/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- In-process TLS (optionally mTLS) `Grpc.Server`, configured entirely from
    the environment so `TlsLoopback` can spawn it as a subprocess:
    * `GRPC_PORT` — listen port (default 50060)
    * `TLS_CERT` / `TLS_KEY` — server certificate/key (PEM)
    * `TLS_CLIENT_CA` — when set, requires and verifies a client certificate
      signed by this CA (mTLS) -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50060").toNat?.getD 50060 |>.toUInt16
  let cert := (← IO.getEnv "TLS_CERT").getD ""
  let key := (← IO.getEnv "TLS_KEY").getD ""
  let clientCa ← IO.getEnv "TLS_CLIENT_CA"
  let mut s := Grpc.Server.empty
  s := Grpc.Server.register s "grpc.testing.TestService" "EmptyCall" fun _ => do
    return (ByteArray.empty, { code := .ok })
  let tlsCfg : Grpc.Tls.Config := {
    certPath := some (System.FilePath.mk cert)
    keyPath := some (System.FilePath.mk key)
    clientCaPath := clientCa.map System.FilePath.mk
  }
  Grpc.Server.serveTls s tlsCfg { host := "127.0.0.1", port }
