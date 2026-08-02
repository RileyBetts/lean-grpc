/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- In-process TLS + mTLS loopback: spawns `tlsServer` (see `Tests/TlsServer.lean`)
    with a self-signed CA/server/client cert chain generated on the fly via the
    system `openssl` CLI, then verifies:
    1. Plain TLS (server cert only) succeeds without a client cert.
    2. mTLS (server requires a client cert) rejects a client that presents none.
    3. mTLS succeeds when the client presents a certificate signed by the
       configured client CA.
    Skips (prints a note and exits 0) if `openssl` is unavailable, since some
    sandboxes don't ship it. -/

private def run (cmd : String) (args : Array String) : IO Unit := do
  let out ← IO.Process.output { cmd, args }
  if out.exitCode != 0 then
    throw (IO.userError s!"{cmd} {args} failed: {out.stderr}")

private def haveOpenssl : IO Bool := do
  try
    let out ← IO.Process.output { cmd := "openssl", args := #["version"] }
    return out.exitCode == 0
  catch _ => return false

private def genCerts (dir : System.FilePath) : IO Unit := do
  IO.FS.createDirAll dir
  let d := dir.toString
  run "openssl" #["genrsa", "-out", s!"{d}/ca.key", "2048"]
  run "openssl" #["req", "-x509", "-new", "-nodes", "-key", s!"{d}/ca.key", "-sha256",
    "-days", "3650", "-out", s!"{d}/ca.crt", "-subj", "/CN=LeanGrpcTestCA"]
  run "openssl" #["genrsa", "-out", s!"{d}/server.key", "2048"]
  run "openssl" #["req", "-new", "-key", s!"{d}/server.key", "-out", s!"{d}/server.csr",
    "-subj", "/CN=127.0.0.1"]
  run "openssl" #["x509", "-req", "-in", s!"{d}/server.csr", "-CA", s!"{d}/ca.crt",
    "-CAkey", s!"{d}/ca.key", "-CAcreateserial", "-out", s!"{d}/server.crt",
    "-days", "825", "-sha256"]
  run "openssl" #["genrsa", "-out", s!"{d}/client.key", "2048"]
  run "openssl" #["req", "-new", "-key", s!"{d}/client.key", "-out", s!"{d}/client.csr",
    "-subj", "/CN=lean-grpc-test-client"]
  run "openssl" #["x509", "-req", "-in", s!"{d}/client.csr", "-CA", s!"{d}/ca.crt",
    "-CAkey", s!"{d}/ca.key", "-CAcreateserial", "-out", s!"{d}/client.crt",
    "-days", "825", "-sha256"]

private def spawnServer (binDir dir : System.FilePath) (port : UInt16) (requireClientCa : Bool) :
    IO (IO.Process.Child {}) := do
  let d := dir.toString
  let env :=
    #[("GRPC_PORT", some (toString port.toNat)),
      ("TLS_CERT", some s!"{d}/server.crt"),
      ("TLS_KEY", some s!"{d}/server.key")] ++
    (if requireClientCa then #[("TLS_CLIENT_CA", some s!"{d}/ca.crt")] else #[])
  IO.Process.spawn { cmd := (binDir / "tlsServer").toString, env }

private def emptyCall (port : UInt16) (cfg : Grpc.Tls.Config) : IO Grpc.CallResult := do
  let conn ← Grpc.Tls.connectH2 "127.0.0.1" port cfg
  Grpc.Client.unaryCall conn "grpc.testing.TestService" "EmptyCall" "127.0.0.1" ByteArray.empty
    (useHttps := true)

/-- Retry a dial+call a few times with backoff, tolerating the spawned server not
    having bound its listen socket yet on a slow/loaded machine. -/
private partial def emptyCallRetry (port : UInt16) (cfg : Grpc.Tls.Config) (attempts : Nat := 5) :
    IO Grpc.CallResult := do
  try
    emptyCall port cfg
  catch e =>
    if attempts ≤ 1 then throw e
    IO.sleep 300
    emptyCallRetry port cfg (attempts - 1)

def main : IO Unit := do
  if !(← haveOpenssl) then
    IO.println "tlsLoopback SKIPPED (no openssl)"
    return
  let dir := (← IO.currentDir) / ".lake" / "build" / "tls-loopback-certs"
  genCerts dir
  let binDir ← IO.appDir
  let serverName := some "127.0.0.1"

  -- 1. Plain TLS (server cert only, no client-CA requirement).
  let port1 : UInt16 := 50061
  let srv1 ← spawnServer binDir dir port1 false
  try
    IO.sleep 300
    let cfg : Grpc.Tls.Config := { caPath := some (dir / "ca.crt"), serverName }
    let res ← emptyCallRetry port1 cfg
    if res.status.code != .ok then
      throw (IO.userError s!"plain tls status {res.status.code.toUInt32}")
  finally
    srv1.kill

  -- 2. mTLS required, client presents no certificate → handshake must fail.
  let port2 : UInt16 := 50062
  let srv2 ← spawnServer binDir dir port2 true
  try
    IO.sleep 600
    let cfg : Grpc.Tls.Config := { caPath := some (dir / "ca.crt"), serverName }
    let mut rejected := false
    try
      discard <| emptyCall port2 cfg
    catch _ =>
      rejected := true
    if !rejected then throw (IO.userError "mtls: expected handshake failure without client cert")
  finally
    srv2.kill

  -- 3. mTLS required, client presents a cert signed by the trusted CA → succeeds.
  let port3 : UInt16 := 50063
  let srv3 ← spawnServer binDir dir port3 true
  try
    IO.sleep 300
    let cfg : Grpc.Tls.Config := {
      caPath := some (dir / "ca.crt")
      certPath := some (dir / "client.crt")
      keyPath := some (dir / "client.key")
      serverName
    }
    let res ← emptyCallRetry port3 cfg
    if res.status.code != .ok then
      throw (IO.userError s!"mtls status {res.status.code.toUInt32}")
  finally
    srv3.kill

  IO.println "tlsLoopback OK"
