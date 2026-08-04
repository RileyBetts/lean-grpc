/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- In-process TLS (optionally mTLS) `Grpc.Server`, configured from the environment
    so `TlsLoopback` can spawn it as a subprocess:
    * `GRPC_PORT` — listen port (default 50060)
    * `TLS_CERT` / `TLS_KEY` — server certificate/key (PEM); omit both for h2c
    * `TLS_CLIENT_CA` — when set, requires and verifies a client certificate
      signed by this CA (mTLS)
    * `TLS_H2C=1` — force plaintext h2c (peerIdentity must be none)

    `EmptyCall` is registered with `registerWithContext` and returns a UTF-8
    identity echo body for IAM loopback assertions. -/

private def utf8 (s : String) : ByteArray := s.toUTF8

private def echoIdentity (ctx : Grpc.ServerCallContext) : ByteArray :=
  let cn :=
    match ctx.peerIdentity with
    | some id => id.commonName
    | none => ""
  let uri :=
    match ctx.peerIdentity with
    | some id => id.uriSans.getD 0 ""
    | none => ""
  let subject :=
    match ctx.peerIdentity with
    | some id => id.subjectDn
    | none => ""
  let fp :=
    match ctx.peerIdentity with
    | some id => id.fingerprintSha256
    | none => ""
  let forged := (ctx.metadata.get? "x-client-subject").getD ""
  let peerNone := if ctx.peerIdentity.isNone then "true" else "false"
  let mtls := if ctx.mtlsRequired then "true" else "false"
  utf8 s!"cn={cn}\nuri={uri}\nsubject={subject}\nfp={fp}\nmd_x_client_subject={forged}\npeer_none={peerNone}\nmtls_required={mtls}\n"

def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50060").toNat?.getD 50060 |>.toUInt16
  let h2c := (← IO.getEnv "TLS_H2C") == some "1"
  let cert := (← IO.getEnv "TLS_CERT").getD ""
  let key := (← IO.getEnv "TLS_KEY").getD ""
  let clientCa ← IO.getEnv "TLS_CLIENT_CA"
  let mut s := Grpc.Server.empty
  s := Grpc.Server.registerWithContext s "grpc.testing.TestService" "EmptyCall" fun ctx _ => do
    return (echoIdentity ctx, { code := .ok })
  if h2c || cert.isEmpty || key.isEmpty then
    IO.println s!"H2c identity server on 127.0.0.1:{port}"
    Grpc.Server.serveH2c s { host := "127.0.0.1", port }
  else
    let tlsCfg : Grpc.Tls.Config := {
      certPath := some (System.FilePath.mk cert)
      keyPath := some (System.FilePath.mk key)
      clientCaPath := clientCa.map System.FilePath.mk
    }
    Grpc.Server.serveTls s tlsCfg { host := "127.0.0.1", port }
