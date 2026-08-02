/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import H2
import Proto
import Bytes.Pool
import Bytes.Slice

/-- Internal helper mode used by the `LEAN_GRPC_RESOLVE_ADDRS` test below: since
    the resolver override is read from the process environment, we re-exec this
    binary as a subprocess with the override set rather than mutating the
    running process's own environment (which Lean's `IO` does not expose). -/
def runResolverEnvCheck : IO Unit := do
  let addrs ← Grpc.Resolver.resolve "dns:///ignored.example:1234"
  for a in addrs do
    IO.println s!"{a.host}:{a.port}"

def main (args : List String) : IO Unit := do
  if args == ["--resolver-env-check"] then
    runResolverEnvCheck
    return
  let msg := Grpc.Message.encodeId (Proto.HelloRequest.encode { name := "x" })
  match Grpc.Message.decodeOne (Bytes.Slice.ofByteArray msg) with
  | .error e => throw (IO.userError e)
  | .ok (p, rest) =>
    if !rest.isEmpty then throw (IO.userError "rest")
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "x" then throw (IO.userError "name")
  if Grpc.StatusCode.ok.toUInt32 != 0 then throw (IO.userError "status")

  -- gzip message framing round-trip (stored deflate)
  let raw := Proto.HelloRequest.encode { name := "gz" }
  let gzMsg ← IO.ofExcept (Grpc.Message.encode raw .gzip)
  match Grpc.Message.decodeOne (Bytes.Slice.ofByteArray gzMsg) with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "gz" then throw (IO.userError "gzip name")

  -- peer-compatible gzip via system gzip (deflate)
  let peerMsg ← Grpc.Message.encodeIO raw .gzip
  match ← Grpc.Message.decodeOneIO (Bytes.Slice.ofByteArray peerMsg) with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "gz" then throw (IO.userError "peer gzip name")
  -- peer inflate of stored gzip still works
  match ← Grpc.Message.decodeOneIO (Bytes.Slice.ofByteArray gzMsg) with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "gz" then throw (IO.userError "stored via peer path")

  -- Invariant: multi-frame gzip stream must decode via decodeAllIO / decodeOneIO
  -- (the VaultGauntlet bug class — stored-only inflate breaks peer frames).
  let rawA := Proto.HelloRequest.encode { name := "a" }
  let rawB := Proto.HelloRequest.encode { name := "b" }
  let frameA ← Grpc.Message.encodeIO rawA .gzip
  let frameB ← Grpc.Message.encodeIO rawB .gzip
  let streamBody := Bytes.Pool.pushBytes frameA frameB
  match ← Grpc.Message.decodeAllIO (Bytes.Slice.ofByteArray streamBody) true .gzip with
  | .error e => throw (IO.userError s!"multi gzip decodeAllIO {e}")
  | .ok ps =>
    if ps.size != 2 then throw (IO.userError s!"multi gzip count {ps.size}")
    let a ← IO.ofExcept (Proto.HelloRequest.decode ps[0]!)
    let b ← IO.ofExcept (Proto.HelloRequest.decode ps[1]!)
    if a.name != "a" || b.name != "b" then throw (IO.userError "multi gzip names")
  -- Same stream decoded one frame at a time (StreamReader.recv? path).
  match ← Grpc.Message.decodeOneIO (Bytes.Slice.ofByteArray streamBody) true .gzip with
  | .error e => throw (IO.userError s!"multi gzip decodeOneIO {e}")
  | .ok (p0, rest) =>
    let a ← IO.ofExcept (Proto.HelloRequest.decode p0)
    if a.name != "a" then throw (IO.userError "decodeOneIO first")
    match ← Grpc.Message.decodeOneIO rest true .gzip with
    | .error e => throw (IO.userError s!"multi gzip decodeOneIO2 {e}")
    | .ok (p1, rest2) =>
      let b ← IO.ofExcept (Proto.HelloRequest.decode p1)
      if b.name != "b" || !rest2.isEmpty then throw (IO.userError "decodeOneIO second")

  -- Invariant: client halfClose sends empty DATA + END_STREAM (grpc-go style).
  -- Empty payload + endStream must not be treated as an app-level empty request
  -- that wipes incremental bidi state (SignalWeave bug class).
  let emptyHalfClose := H2.Frame.data 1 ByteArray.empty true
  if emptyHalfClose.payload.size != 0 then throw (IO.userError "halfclose payload")
  if !H2.Flags.has emptyHalfClose.flags H2.Flags.endStream then
    throw (IO.userError "halfclose endStream flag")
  -- H2 stream bookkeeping: after consuming all buffered data, fresh slice is empty.
  let s0 := H2.Stream.create 1 65535 65535
  let s1 := { s0 with dataBuf := ByteArray.mk #[1, 2, 3, 4], dataConsumed := 4 }
  let fresh := s1.dataBuf.extract s1.dataConsumed s1.dataBuf.size
  if fresh.size != 0 then throw (IO.userError "dataConsumed fresh nonempty")

  -- deflate (zlib) round-trip, pure + peer-compatible
  let rawDf := Proto.HelloRequest.encode { name := "df" }
  let dfMsg ← IO.ofExcept (Grpc.Message.encode rawDf .deflate)
  match Grpc.Message.decodeOne (Bytes.Slice.ofByteArray dfMsg) true .deflate with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "df" then throw (IO.userError "deflate name")
  let dfPeer ← Grpc.Message.encodeIO rawDf .deflate
  match ← Grpc.Message.decodeOneIO (Bytes.Slice.ofByteArray dfPeer) true .deflate with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "df" then throw (IO.userError "deflate peer name")

  -- snappy (literal framing) round-trip
  let rawSn := Proto.HelloRequest.encode { name := "sn" }
  let snMsg ← IO.ofExcept (Grpc.Message.encode rawSn .snappy)
  match Grpc.Message.decodeOne (Bytes.Slice.ofByteArray snMsg) true .snappy with
  | .error e => throw (IO.userError e)
  | .ok (p, _) =>
    let r ← IO.ofExcept (Proto.HelloRequest.decode p)
    if r.name != "sn" then throw (IO.userError "snappy name")
  -- exercise the multi-byte literal length path (> 60 bytes).
  let bigSn := ByteArray.mk (Array.replicate 5000 (65 : UInt8))
  let bigEnc := Grpc.Compression.snappyEncodeLiteral bigSn
  match Grpc.Compression.snappyDecodeLiteral bigEnc with
  | .error e => throw (IO.userError s!"snappy big {e}")
  | .ok back => if back != bigSn then throw (IO.userError "snappy big roundtrip")

  -- negotiate: gzip > deflate > snappy > identity
  if Grpc.Compression.negotiate "identity,deflate,snappy,gzip" != .gzip then
    throw (IO.userError "negotiate gzip priority")
  if Grpc.Compression.negotiate "identity,deflate,snappy" != .deflate then
    throw (IO.userError "negotiate deflate priority")
  if Grpc.Compression.negotiate "identity,snappy" != .snappy then
    throw (IO.userError "negotiate snappy priority")
  if Grpc.Compression.negotiate "identity" != .identity then
    throw (IO.userError "negotiate identity")

  -- percent encode/decode
  let enc := Grpc.Metadata.percentEncode "hello world/x"
  if !enc.contains '%' then throw (IO.userError s!"pct enc {enc}")
  let dec := Grpc.Metadata.percentDecode enc
  if dec != "hello world/x" then throw (IO.userError s!"pct {dec}")

  -- base64 bin metadata
  let bin := ByteArray.mk #[1, 2, 3, 4]
  let b64 := Grpc.Metadata.base64Encode bin
  let back ← IO.ofExcept (Grpc.Metadata.base64Decode b64)
  if back != bin then throw (IO.userError "b64")

  -- timeout parse
  match Grpc.Metadata.parseTimeoutMs "10S" with
  | some 10000 => pure ()
  | _ => throw (IO.userError "timeout S")
  match Grpc.Metadata.parseTimeoutMs "1n" with
  | some 0 => pure ()
  | _ => throw (IO.userError "timeout n")
  match Grpc.Metadata.parseTimeoutMs "1500u" with
  | some 1 => pure ()
  | _ => throw (IO.userError "timeout u")

  -- getBin + status details
  let md0 := Grpc.Metadata.addBin {} "custom-bin" (ByteArray.mk #[9, 8, 7])
  match Grpc.Metadata.getBin? md0 "custom-bin" with
  | .ok (some b) => if b != ByteArray.mk #[9, 8, 7] then throw (IO.userError "getBin")
  | .ok none => throw (IO.userError "getBin missing")
  | .error e => throw (IO.userError s!"getBin error {e}")
  let stDet : Grpc.Status := { code := .internal, message := "boom" }
  let detBytes := Grpc.StatusDetails.encode stDet
  let rpc ← IO.ofExcept (Grpc.StatusDetails.decode detBytes .internal)
  if rpc.message != "boom" then throw (IO.userError "status details")
  match Grpc.StatusDetails.decode detBytes .cancelled with
  | .error _ => pure ()
  | .ok _ => throw (IO.userError "details should contradict")

  -- user-agent / scheme helpers
  let ua := Grpc.Metadata.userAgent "1.0.0"
  let (uan, uav) :=
    (String.ofList (ua.name.toList.map (fun b => Char.ofNat b.toNat)),
     String.ofList (ua.value.toList.map (fun b => Char.ofNat b.toNat)))
  if uan != "user-agent" || uav != "grpc-lean/1.0.0" then throw (IO.userError "ua")
  let https := Grpc.Metadata.schemeHttps
  let hv := String.ofList (https.value.toList.map (fun b => Char.ofNat b.toNat))
  if hv != "https" then throw (IO.userError "scheme")

  -- RST → status mapping
  let rstTrailers := H2.Client.rstToTrailers 8
  let mut rstCode := ""
  for h in rstTrailers do
    let n := String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat))
    let v := String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat))
    if n == "grpc-status" then rstCode := v
  if rstCode != "1" then throw (IO.userError s!"rst cancel got {rstCode}")
  let refused := H2.Client.rstToTrailers 7
  let mut refusedCode := ""
  for h in refused do
    let n := String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat))
    let v := String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat))
    if n == "grpc-status" then refusedCode := v
  if refusedCode != "14" then throw (IO.userError "rst refused")

  -- trailers-only + 415 helpers
  let to := Grpc.Metadata.trailersOnly (.unimplemented "x")
  let mut saw415 := false
  for h in Grpc.Metadata.http415 do
    let n := String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat))
    let v := String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat))
    if n == ":status" && v == "415" then saw415 := true
  if !saw415 then throw (IO.userError "http415")
  if to.size < 3 then throw (IO.userError "trailersOnly")

  -- UTF-8 percent encode (special_status_message)
  let msg := "BMP ☺ emoji 😈"
  let enc := Grpc.Metadata.percentEncode msg
  if !(enc.contains "%E2") then throw (IO.userError s!"pct utf8 {enc}")
  if Grpc.Metadata.percentDecode enc != msg then throw (IO.userError "pct roundtrip")

  -- Resolver / service config / retry
  let addr ← IO.ofExcept (Grpc.Resolver.parseTarget "dns:///127.0.0.1:10000")
  if addr.port != 10000 then throw (IO.userError "resolver port")
  let cfg := Grpc.ServiceConfig.parse "{\"loadBalancingPolicy\":\"round_robin\",\"timeout\":\"1s\"}"
  if cfg.loadBalancingPolicy != "round_robin" then throw (IO.userError "lb policy")
  if cfg.timeoutMs != some 1000 then throw (IO.userError "svc timeout")
  let policy : Grpc.ServiceConfig.RetryPolicy := { maxAttempts := 3, retryableStatusCodes := #[14] }
  if !Grpc.Retry.shouldRetry policy .unavailable 0 then throw (IO.userError "retry")
  if Grpc.Retry.shouldRetry policy .ok 0 then throw (IO.userError "no retry ok")

  -- Credentials compose
  let creds := Grpc.Credentials.CallCredentials.composite
    (Grpc.Credentials.CallCredentials.accessToken "t")
    (Grpc.Credentials.CallCredentials.jwt "j.w.t")
  let md ← creds.apply {}
  if (md.get? "authorization").isNone then throw (IO.userError "creds")

  -- Well-known Any + map
  let anyB := Proto.WellKnown.AnyMsg.encode { typeUrl := "type.googleapis.com/x", value := ByteArray.mk #[1] }
  let any ← IO.ofExcept (Proto.WellKnown.AnyMsg.decode anyB)
  if any.typeUrl != "type.googleapis.com/x" then throw (IO.userError "any")

  -- Proto UTF-8 strings
  let es := Proto.EchoStatus.encode { code := 2, message := "☺" }
  let esd ← IO.ofExcept (Proto.EchoStatus.decode es)
  if esd.message != "☺" then throw (IO.userError "echo utf8")

  -- GCP allowlist non-empty
  if Grpc.Gcp.deferredCases.isEmpty then throw (IO.userError "gcp allowlist")

  -- JWT fixture + ORCA + xDS bootstrap
  let jwt := Grpc.Jwt.fixtureUnsigned "u@example.com"
  if Grpc.Jwt.usernameFromAuthorization s!"Bearer {jwt}" != "u@example.com" then
    throw (IO.userError "jwt claim")
  let orca : Grpc.Orca.Report := { cpuUtilization := 0.1, memUtilization := 0.2 }
  let orca2 ← IO.ofExcept (Grpc.Orca.Report.decode (Grpc.Orca.Report.encode orca))
  if orca2 != orca then throw (IO.userError "orca roundtrip")
  let boot := Grpc.Xds.parseBootstrap "{\"clusters\":{\"c\":[\"127.0.0.1:9\"]}}"
  let xs ← IO.ofExcept (Grpc.Xds.resolve boot "xds:///c")
  if xs.size != 1 then throw (IO.userError "xds resolve")
  let hedge := Grpc.ServiceConfig.parse "{\"hedgingPolicy\":{}}"
  if hedge.hedging.isNone then throw (IO.userError "hedge parse")

  -- Balancer: round_robin advances through addresses in order and wraps;
  -- pick_first always returns the first address without advancing.
  let addrsRR : Array Grpc.Resolver.Address :=
    #[{ host := "10.0.0.1", port := 50051 }, { host := "10.0.0.2", port := 50051 },
      { host := "10.0.0.3", port := 50051 }]
  let balRR0 := Grpc.Balancer.create .roundRobin addrsRR
  let (p0, balRR1) := Grpc.Balancer.pick balRR0
  let (p1, balRR2) := Grpc.Balancer.pick balRR1
  let (p2, balRR3) := Grpc.Balancer.pick balRR2
  let (p3, _) := Grpc.Balancer.pick balRR3
  if p0 != some addrsRR[0]! then throw (IO.userError "rr pick 0")
  if p1 != some addrsRR[1]! then throw (IO.userError "rr pick 1")
  if p2 != some addrsRR[2]! then throw (IO.userError "rr pick 2")
  if p3 != some addrsRR[0]! then throw (IO.userError "rr pick wrap")
  let balPF0 := Grpc.Balancer.create .pickFirst addrsRR
  let (pf0, balPF1) := Grpc.Balancer.pick balPF0
  let (pf1, _) := Grpc.Balancer.pick balPF1
  if pf0 != some addrsRR[0]! then throw (IO.userError "pick_first 0")
  if pf1 != some addrsRR[0]! then throw (IO.userError "pick_first stays")

  -- ServiceConfig: fuller JSON with loadBalancingConfig, retryPolicy (named
  -- status codes, fractional-second durations), and methodConfig timeout.
  let fullCfg := Grpc.ServiceConfig.parse "{\
\"loadBalancingConfig\":[{\"round_robin\":{}}],\
\"methodConfig\":[{\
\"timeout\":\"0.5s\",\
\"retryPolicy\":{\
\"maxAttempts\":4,\
\"initialBackoff\":\"0.1s\",\
\"maxBackoff\":\"1s\",\
\"backoffMultiplier\":2,\
\"retryableStatusCodes\":[\"UNAVAILABLE\",\"ABORTED\"]\
}\
}]\
}"
  if fullCfg.loadBalancingPolicy != "round_robin" then
    throw (IO.userError s!"svcconfig lb from array {fullCfg.loadBalancingPolicy}")
  if fullCfg.timeoutMs != some 500 then
    throw (IO.userError s!"svcconfig methodConfig timeout {fullCfg.timeoutMs}")
  match fullCfg.retry with
  | none => throw (IO.userError "svcconfig retry missing")
  | some rp =>
    if rp.maxAttempts != 4 then throw (IO.userError s!"svcconfig retry maxAttempts {rp.maxAttempts}")
    if rp.initialBackoffMs != 100 then
      throw (IO.userError s!"svcconfig retry initialBackoff {rp.initialBackoffMs}")
    if rp.maxBackoffMs != 1000 then
      throw (IO.userError s!"svcconfig retry maxBackoff {rp.maxBackoffMs}")
    if rp.retryableStatusCodes != #[14, 10] then
      throw (IO.userError s!"svcconfig retry codes {rp.retryableStatusCodes}")
  -- Hedging policy with explicit fields.
  let hedgeCfg := Grpc.ServiceConfig.parse
    "{\"methodConfig\":[{\"hedgingPolicy\":{\"maxAttempts\":3,\"hedgingDelay\":\"10ms\",\"nonFatalStatusCodes\":[\"UNAVAILABLE\"]}}]}"
  match hedgeCfg.hedging with
  | none => throw (IO.userError "svcconfig hedging missing")
  | some hp =>
    if hp.maxAttempts != 3 then throw (IO.userError s!"svcconfig hedge maxAttempts {hp.maxAttempts}")
    if hp.hedgingDelayMs != 10 then throw (IO.userError s!"svcconfig hedge delay {hp.hedgingDelayMs}")
  -- Malformed JSON falls back to defaults rather than throwing.
  let badCfg := Grpc.ServiceConfig.parse "not json"
  if badCfg.loadBalancingPolicy != "pick_first" then throw (IO.userError "svcconfig bad json fallback")

  -- Resolver: LEAN_GRPC_RESOLVE_ADDRS overrides DNS with a deterministic list.
  -- Exercised via a re-exec'd subprocess since Lean's `IO` has no way to
  -- mutate the current process's environment.
  let selfPath ← IO.appPath
  let envOut ← IO.Process.output {
    cmd := selfPath.toString
    args := #["--resolver-env-check"]
    env := #[
      ("LEAN_GRPC_RESOLVE_ADDRS", some "10.9.0.1:9001, 10.9.0.2:9002"),
      ("LEAN_GRPC_ALLOW_RESOLVE_OVERRIDE", some "1")
    ]
  }
  if envOut.exitCode != 0 then
    throw (IO.userError s!"resolver env override subprocess failed: {envOut.stderr}")
  let expected := "10.9.0.1:9001\n10.9.0.2:9002\n"
  if envOut.stdout != expected then
    throw (IO.userError s!"resolver env override got {envOut.stdout}")

  IO.println "grpcTests OK"
