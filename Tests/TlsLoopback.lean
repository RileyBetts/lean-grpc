/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- In-process TLS + mTLS + IAM identity loopback: spawns `tlsServer` with a
    self-signed CA/server/client cert chain generated via `openssl`, then verifies:
    1. Plain TLS (server cert only) succeeds without a client cert.
    2. mTLS (server requires a client cert) rejects a client that presents none.
    3. mTLS succeeds when the client presents a certificate signed by the CA;
       handler observes `peerIdentity.commonName` / URI SAN.
    4. Two different client certs → two different peer identities.
    5. Attacker metadata `x-client-subject` does not forge `peerIdentity`.
    6. h2c → `peerIdentity = none`.
    7. Failed handshake against mTLS listener does not kill the accept loop.
    Skips (exit 0) if `openssl` is unavailable. -/

private def run (cmd : String) (args : Array String) : IO Unit := do
  let out ← IO.Process.output { cmd, args }
  if out.exitCode != 0 then
    throw (IO.userError s!"{cmd} {args} failed: {out.stderr}")

private def haveOpenssl : IO Bool := do
  try
    let out ← IO.Process.output { cmd := "openssl", args := #["version"] }
    return out.exitCode == 0
  catch _ => return false

private def writeFile (path : System.FilePath) (contents : String) : IO Unit :=
  IO.FS.writeFile path contents

/-- Generate CA, server, and two distinct client certs (CN + URI SAN). -/
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

  -- Client A: CN=oms-desk-a + SPIFFE-shaped URI SAN
  writeFile (dir / "client_a_ext.cnf")
    "subjectAltName=URI:spiffe://lean-grpc.test/oms-desk-a\n"
  run "openssl" #["genrsa", "-out", s!"{d}/client_a.key", "2048"]
  run "openssl" #["req", "-new", "-key", s!"{d}/client_a.key", "-out", s!"{d}/client_a.csr",
    "-subj", "/CN=oms-desk-a"]
  run "openssl" #["x509", "-req", "-in", s!"{d}/client_a.csr", "-CA", s!"{d}/ca.crt",
    "-CAkey", s!"{d}/ca.key", "-CAcreateserial", "-out", s!"{d}/client_a.crt",
    "-days", "825", "-sha256", "-extfile", s!"{d}/client_a_ext.cnf"]

  -- Client B: CN=admin + different URI SAN
  writeFile (dir / "client_b_ext.cnf")
    "subjectAltName=URI:spiffe://lean-grpc.test/admin\n"
  run "openssl" #["genrsa", "-out", s!"{d}/client_b.key", "2048"]
  run "openssl" #["req", "-new", "-key", s!"{d}/client_b.key", "-out", s!"{d}/client_b.csr",
    "-subj", "/CN=admin"]
  run "openssl" #["x509", "-req", "-in", s!"{d}/client_b.csr", "-CA", s!"{d}/ca.crt",
    "-CAkey", s!"{d}/ca.key", "-CAcreateserial", "-out", s!"{d}/client_b.crt",
    "-days", "825", "-sha256", "-extfile", s!"{d}/client_b_ext.cnf"]

  -- Backward-compat names used by plain mTLS case
  run "cp" #[s!"{d}/client_a.crt", s!"{d}/client.crt"]
  run "cp" #[s!"{d}/client_a.key", s!"{d}/client.key"]

private def spawnServer (binDir dir : System.FilePath) (port : UInt16)
    (requireClientCa : Bool) (h2c : Bool := false) : IO (IO.Process.Child {}) := do
  let d := dir.toString
  let mut env : Array (String × Option String) :=
    #[("GRPC_PORT", some (toString port.toNat))]
  if h2c then
    env := env.push ("TLS_H2C", some "1")
  else
    env := env ++
      #[("TLS_CERT", some s!"{d}/server.crt"),
        ("TLS_KEY", some s!"{d}/server.key")]
    if requireClientCa then
      env := env.push ("TLS_CLIENT_CA", some s!"{d}/ca.crt")
  IO.Process.spawn { cmd := (binDir / "tlsServer").toString, env }

private def field (body : String) (key : String) : String :=
  let keyEq := key ++ "="
  Id.run do
    for line in body.splitOn "\n" do
      if line.startsWith keyEq then
        return (line.drop keyEq.length).toString
    return ""

private def bodyString (res : Grpc.CallResult) : IO String := do
  match String.fromUTF8? res.message with
  | some s => pure s
  | none => throw (IO.userError "identity echo: non-utf8 body")

private def emptyCall (port : UInt16) (cfg : Grpc.Tls.Config)
    (extra : Array Hpack.HeaderField := #[]) (useHttps : Bool := true) : IO Grpc.CallResult := do
  let conn ←
    if useHttps then
      Grpc.Tls.connectH2 "127.0.0.1" port cfg
    else
      H2.Client.connectH2c "127.0.0.1" port
  Grpc.Client.unaryCall conn "grpc.testing.TestService" "EmptyCall" "127.0.0.1" ByteArray.empty
    extra (useHttps := useHttps)

private partial def emptyCallRetry (port : UInt16) (cfg : Grpc.Tls.Config)
    (extra : Array Hpack.HeaderField := #[]) (useHttps : Bool := true) (attempts : Nat := 8) :
    IO Grpc.CallResult := do
  try
    emptyCall port cfg extra useHttps
  catch e =>
    if attempts ≤ 1 then throw e
    IO.sleep 300
    emptyCallRetry port cfg extra useHttps (attempts - 1)

def main : IO Unit := do
  if !(← haveOpenssl) then
    IO.println "tlsLoopback SKIPPED (no openssl)"
    return
  let dir := (← IO.currentDir) / ".lake" / "build" / "tls-loopback-certs"
  genCerts dir
  let binDir ← IO.appDir
  let serverName := some "127.0.0.1"
  let caPath := some (dir / "ca.crt")

  -- 1. Plain TLS (server cert only, no client-CA requirement).
  let port1 : UInt16 := 50061
  let srv1 ← spawnServer binDir dir port1 false
  try
    IO.sleep 300
    let cfg : Grpc.Tls.Config := { caPath, serverName }
    let res ← emptyCallRetry port1 cfg
    if res.status.code != .ok then
      throw (IO.userError s!"plain tls status {res.status.code.toUInt32}")
    let body ← bodyString res
    if field body "peer_none" != "true" then
      throw (IO.userError s!"plain tls expected peer_none: {body}")
  finally
    srv1.kill

  -- 2. mTLS required, client presents no certificate → handshake must fail.
  let port2 : UInt16 := 50062
  let srv2 ← spawnServer binDir dir port2 true
  try
    IO.sleep 600
    let cfg : Grpc.Tls.Config := { caPath, serverName }
    let mut rejected := false
    try
      discard <| emptyCall port2 cfg
    catch _ =>
      rejected := true
    if !rejected then throw (IO.userError "mtls: expected handshake failure without client cert")
  finally
    srv2.kill

  -- 3. mTLS + client A → handler observes CN / URI SAN.
  let port3 : UInt16 := 50063
  let srv3 ← spawnServer binDir dir port3 true
  try
    IO.sleep 300
    let cfgA : Grpc.Tls.Config := {
      caPath
      certPath := some (dir / "client_a.crt")
      keyPath := some (dir / "client_a.key")
      serverName
    }
    let res ← emptyCallRetry port3 cfgA
    if res.status.code != .ok then
      throw (IO.userError s!"mtls A status {res.status.code.toUInt32}")
    let body ← bodyString res
    if field body "cn" != "oms-desk-a" then
      throw (IO.userError s!"mtls A unexpected cn: {body}")
    if field body "uri" != "spiffe://lean-grpc.test/oms-desk-a" then
      throw (IO.userError s!"mtls A unexpected uri: {body}")
    if field body "peer_none" != "false" then
      throw (IO.userError s!"mtls A expected peer: {body}")
    if (field body "fp").isEmpty then
      throw (IO.userError s!"mtls A missing fingerprint: {body}")

    -- 4. Same server, client B → different identity.
    let cfgB : Grpc.Tls.Config := {
      caPath
      certPath := some (dir / "client_b.crt")
      keyPath := some (dir / "client_b.key")
      serverName
    }
    let resB ← emptyCallRetry port3 cfgB
    if resB.status.code != .ok then
      throw (IO.userError s!"mtls B status {resB.status.code.toUInt32}")
    let bodyB ← bodyString resB
    if field bodyB "cn" != "admin" then
      throw (IO.userError s!"mtls B unexpected cn: {bodyB}")
    if field bodyB "uri" != "spiffe://lean-grpc.test/admin" then
      throw (IO.userError s!"mtls B unexpected uri: {bodyB}")
    if field body "cn" == field bodyB "cn" then
      throw (IO.userError "mtls: expected distinct CNs for client A vs B")
    if field body "fp" == field bodyB "fp" then
      throw (IO.userError "mtls: expected distinct fingerprints for client A vs B")

    -- 5. Metadata forgery must not appear in peerIdentity (only in raw metadata).
    let forged : Array Hpack.HeaderField :=
      #[⟨Grpc.Metadata.ascii "x-client-subject", Grpc.Metadata.ascii "admin"⟩]
    let resF ← emptyCallRetry port3 cfgA forged
    let bodyF ← bodyString resF
    if field bodyF "cn" != "oms-desk-a" then
      throw (IO.userError s!"forge: peer cn changed by metadata: {bodyF}")
    if field bodyF "md_x_client_subject" != "admin" then
      throw (IO.userError s!"forge: metadata not visible: {bodyF}")
    if (field bodyF "subject").contains "admin" && !(field bodyF "subject").contains "oms-desk-a" then
      throw (IO.userError s!"forge: subject looks forged: {bodyF}")

    -- 7. Accept-loop survival: bad handshake must not kill the server.
    let mut badRejected := false
    try
      discard <| emptyCall port3 { caPath, serverName }
    catch _ =>
      badRejected := true
    if !badRejected then
      throw (IO.userError "accept-loop: expected failed handshake without client cert")
    let resAfter ← emptyCallRetry port3 cfgA
    if resAfter.status.code != .ok then
      throw (IO.userError "accept-loop: server died after failed handshake")
    let bodyAfter ← bodyString resAfter
    if field bodyAfter "cn" != "oms-desk-a" then
      throw (IO.userError s!"accept-loop: bad identity after recovery: {bodyAfter}")
  finally
    srv3.kill

  -- 6. h2c → peerIdentity = none
  let port4 : UInt16 := 50064
  let srv4 ← spawnServer binDir dir port4 false (h2c := true)
  try
    IO.sleep 300
    let res ← emptyCallRetry port4 {} #[] (useHttps := false)
    if res.status.code != .ok then
      throw (IO.userError s!"h2c status {res.status.code.toUInt32}")
    let body ← bodyString res
    if field body "peer_none" != "true" then
      throw (IO.userError s!"h2c expected peer_none: {body}")
    if field body "mtls_required" != "false" then
      throw (IO.userError s!"h2c expected mtls_required=false: {body}")
  finally
    srv4.kill

  IO.println "tlsLoopback OK"
