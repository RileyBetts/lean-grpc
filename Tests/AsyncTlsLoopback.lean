/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import H2
import Proto
import Std.Async
import Std.Async.Timer

open Std.Async

/-- Concurrent off-loop TLS clients + Async h2c on one UV loop (issue #10).
    TLS server runs in a subprocess (`tlsServer`); clients use `H2.runOffLoop` so
    OpenSSL cannot stall the UV loop while h2c clients progress.
    Skips if `openssl` is unavailable. -/

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
    "-days", "3650", "-out", s!"{d}/ca.crt", "-subj", "/CN=LeanGrpcAsyncTlsCA"]
  run "openssl" #["genrsa", "-out", s!"{d}/server.key", "2048"]
  run "openssl" #["req", "-new", "-key", s!"{d}/server.key", "-out", s!"{d}/server.csr",
    "-subj", "/CN=127.0.0.1"]
  run "openssl" #["x509", "-req", "-in", s!"{d}/server.csr", "-CA", s!"{d}/ca.crt",
    "-CAkey", s!"{d}/ca.key", "-CAcreateserial", "-out", s!"{d}/server.crt",
    "-days", "825", "-sha256"]

private def spawnTlsServer (binDir dir : System.FilePath) (port : UInt16) :
    IO (IO.Process.Child {}) := do
  let d := dir.toString
  IO.Process.spawn {
    cmd := (binDir / "tlsServer").toString
    env := #[
      ("GRPC_PORT", some (toString port.toNat)),
      ("TLS_CERT", some s!"{d}/server.crt"),
      ("TLS_KEY", some s!"{d}/server.key")
    ]
  }

/-- Blocking EmptyCall with connect retries (server spawn race). -/
private partial def tlsEmptyIO (port : UInt16) (ca : System.FilePath) (tag : String)
    (attempts : Nat := 12) : IO String := do
  let cfg : Grpc.Tls.Config := {
    caPath := some ca
    serverName := some "127.0.0.1"
  }
  try
    let c ← Grpc.Tls.connectH2 "127.0.0.1" port cfg
    let res ← Grpc.Client.unaryCall c "grpc.testing.TestService" "EmptyCall" "127.0.0.1"
      ByteArray.empty (useHttps := true)
    if res.status.code != .ok then
      throw (IO.userError s!"tls empty status {res.status.code.toUInt32} tag={tag}")
    match String.fromUTF8? res.message with
    | some s => pure s!"{tag}:{s}"
    | none => throw (IO.userError "non-utf8")
  catch e =>
    if attempts ≤ 1 then throw e
    IO.sleep 250
    tlsEmptyIO port ca tag (attempts - 1)

/-- Off-loop TLS EmptyCall client. -/
private def tlsEmptyClient (port : UInt16) (ca : System.FilePath) (tag : String) : Async String :=
  H2.runOffLoop (tlsEmptyIO port ca tag)

private def h2cClient (port : UInt16) (name : String) : Async String := do
  let c ← H2.Client.connectH2cAsync "127.0.0.1" port
  let req := Proto.HelloRequest.encode { name }
  let res ← Grpc.Client.unaryCallAsync c "helloworld.Greeter" "SayHello" "127.0.0.1" req
  if res.status.code != .ok then
    throw (IO.userError s!"h2c status {res.status.code.toUInt32}")
  let reply ← liftM (IO.ofExcept (Proto.HelloReply.decode res.message))
  return reply.message

def main : IO Unit := do
  if !(← haveOpenssl) then
    IO.println "asyncTlsLoopback SKIPPED (no openssl)"
    return
  let dir := (← IO.currentDir) / ".lake" / "build" / "async-tls-loopback-certs"
  genCerts dir
  let binDir ← IO.appDir
  let tlsPort : UInt16 := 50071
  let h2cPort : UInt16 := 50072
  let mut s := Grpc.Server.empty
  s := Grpc.Server.register s "helloworld.Greeter" "SayHello" fun reqBytes => do
    let req ← IO.ofExcept (Proto.HelloRequest.decode reqBytes)
    let reply : Proto.HelloReply := { message := s!"Hello, {req.name}" }
    return (Proto.HelloReply.encode reply, Grpc.Status.ok)
  let srv ← spawnTlsServer binDir dir tlsPort
  try
    (do
      background (prio := Task.Priority.dedicated) do
        Grpc.Server.serveH2cAsync s { host := "127.0.0.1", port := h2cPort }
      sleep (Std.Time.Millisecond.Offset.ofNat 600)
      let tlsTags : Array String := #["T1", "T2", "T3", "T4"]
      let h2cNames : Array String := #["H1", "H2", "H3", "H4"]
      let tlsJobs := tlsTags.map (fun t => tlsEmptyClient tlsPort (dir / "ca.crt") t)
      let h2cJobs := h2cNames.map (fun n => h2cClient h2cPort n)
      let msgs ← Async.concurrentlyAll (tlsJobs ++ h2cJobs)
      if msgs.size != tlsTags.size + h2cNames.size then
        throw (IO.userError s!"expected {tlsTags.size + h2cNames.size} replies, got {msgs.size}")
      for msg in msgs do
        if !("T".isPrefixOf msg || "Hello".isPrefixOf msg) then
          throw (IO.userError msg)
      -- Phase 2: in-process `serveTlsAsync` + off-loop client (same UV loop as h2c).
      let asyncTlsPort : UInt16 := 50073
      let tlsCfg : Grpc.Tls.Config := {
        certPath := some (dir / "server.crt")
        keyPath := some (dir / "server.key")
      }
      let mut s2 := Grpc.Server.empty
      s2 := Grpc.Server.registerWithContext s2 "grpc.testing.TestService" "EmptyCall"
        fun _ _ => pure (ByteArray.empty, Grpc.Status.ok)
      background (prio := Task.Priority.dedicated) do
        Grpc.Server.serveTlsAsync s2 tlsCfg { host := "127.0.0.1", port := asyncTlsPort }
      sleep (Std.Time.Millisecond.Offset.ofNat 400)
      let body ← tlsEmptyClient asyncTlsPort (dir / "ca.crt") "ASYNC"
      if !("ASYNC:".isPrefixOf body) then
        throw (IO.userError body)
      IO.println "asyncTlsLoopback OK"
      -- Background accept loops (h2c + serveTlsAsync) keep dedicated threads alive;
      -- force a clean exit so Lake/CI do not hang in task_manager finalization.
      IO.Process.exit 0
    ).block
  finally
    srv.kill
