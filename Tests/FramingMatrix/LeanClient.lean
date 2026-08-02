/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import H2
import Hpack
import Bytes.Pool
import Bytes.Slice
import Tests.FramingMatrix.Protocol

open Tests.FramingMatrix.Protocol

private def headerAscii (h : Hpack.HeaderField) : String × String :=
  (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
   String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))

private structure Check where
  name : String
  ok : Bool
  detail : String := ""
  deriving Inhabited

private def pass (name : String) (detail : String := "") : Check :=
  { name, ok := true, detail }

private def fail (name : String) (detail : String) : Check :=
  { name, ok := false, detail }

private def expectCode (name : String) (got : Grpc.StatusCode) (want : Grpc.StatusCode) : Check :=
  if got == want then pass name s!"status={want.toUInt32}"
  else fail name s!"expected {want.toUInt32} got {got.toUInt32}"

private def trailerStatus (headers trailers : Array Hpack.HeaderField) : String :=
  Id.run do
    let mut st := ""
    for h in trailers do
      let (n, v) := headerAscii h
      if n == "grpc-status" then st := v
    for h in headers do
      let (n, v) := headerAscii h
      if n == "grpc-status" then st := v
    return st

/-- Server-stream FanOut over raw H2 with optional response compression negotiate. -/
private def fanOutRaw (host : String) (port : UInt16) (acceptGzip : Bool) : IO Check := do
  let name := if acceptGzip then "lean.fanout.gzip" else "lean.fanout.identity"
  let c ← H2.Client.connectH2c host port
  let mut headers : Array Hpack.HeaderField := #[
    Grpc.Metadata.methodPost,
    Grpc.Metadata.schemeHttp,
    ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
    Grpc.Metadata.path serviceName "FanOut",
    Grpc.Metadata.contentTypeGrpc,
    Grpc.Metadata.teTrailers,
    Grpc.Metadata.userAgent
  ]
  if acceptGzip then
    headers := headers.push (Grpc.Metadata.grpcAcceptEncoding "identity,gzip")
  let body := Grpc.Message.encodeId (Blob.encode { text := "scan" })
  let resp ← H2.Client.unary c headers body
  let st := trailerStatus resp.headers resp.trailers
  if st != "0" then return fail name s!"grpc-status={st}"
  let payloads ←
    match ← Grpc.Message.decodeAllIO (Bytes.Slice.ofByteArray resp.data) with
    | .ok ps => pure ps
    | .error e => return fail name e
  if payloads.size != 3 then return fail name s!"count={payloads.size}"
  let t0 ← IO.ofExcept (Blob.decode payloads[0]!)
  let t2 ← IO.ofExcept (Blob.decode payloads[2]!)
  if t0.text == "scan:1" && t2.text == "scan:3" then
    return pass name s!"n={payloads.size}"
  else
    return fail name s!"{t0.text}..{t2.text}"

/-- Client-stream Collect with gzip request frames + empty half-close style (single unary body). -/
private def collectGzip (host : String) (port : UInt16) : IO Check := do
  let name := "lean.collect.gzip"
  let c ← H2.Client.connectH2c host port
  let texts := #["aa", "bb", "cc"]
  let mut body := ByteArray.empty
  let mut expect : UInt32 := 0
  for t in texts do
    expect := expect ^^^ foldXorString t
    body := Bytes.Pool.pushBytes body (← Grpc.Message.encodeIO (Blob.encode { text := t }) .gzip)
  let headers : Array Hpack.HeaderField := #[
    Grpc.Metadata.methodPost,
    Grpc.Metadata.schemeHttp,
    ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
    Grpc.Metadata.path serviceName "Collect",
    Grpc.Metadata.contentTypeGrpc,
    Grpc.Metadata.teTrailers,
    Grpc.Metadata.userAgent,
    Grpc.Metadata.grpcEncoding "gzip",
    Grpc.Metadata.grpcAcceptEncoding "identity,gzip"
  ]
  let resp ← H2.Client.unary c headers body
  let st := trailerStatus resp.headers resp.trailers
  if st != "0" then return fail name s!"grpc-status={st}"
  let payloads ←
    match ← Grpc.Message.decodeAllIO (Bytes.Slice.ofByteArray resp.data) with
    | .ok ps => pure ps
    | .error e => return fail name e
  if payloads.isEmpty then return fail name "empty reply"
  let tally ← IO.ofExcept (Tally.decode payloads[0]!)
  if tally.count == 3 && tally.xorFold == expect then
    return pass name s!"xor={tally.xorFold}"
  else
    return fail name s!"count={tally.count} xor={tally.xorFold} want={expect}"

def main (args : List String) : IO UInt32 := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50310").toNat?.getD 50310 |>.toUInt16
  let mut checks : Array Check := #[]
  let ch ← Grpc.Channel.connectH2c host port

  -- Unary identity + gzip
  let echoId ← Grpc.Channel.unary ch serviceName "Echo" (Blob.encode { text := "hi" })
  checks := checks.push (expectCode "lean.echo.identity" echoId.status.code .ok)
  match Blob.decode echoId.message with
  | .ok b =>
    checks := checks.push (if b.text == "echo:hi" then pass "lean.echo.identity.body" b.text
      else fail "lean.echo.identity.body" b.text)
  | .error e => checks := checks.push (fail "lean.echo.identity.body" e)

  let echoGz ← Grpc.Channel.unary ch serviceName "Echo" (Blob.encode { text := "gz" }) {} none .gzip
  checks := checks.push (expectCode "lean.echo.gzip" echoGz.status.code .ok)
  match Blob.decode echoGz.message with
  | .ok b =>
    checks := checks.push (if b.text == "echo:gz" then pass "lean.echo.gzip.body" b.text
      else fail "lean.echo.gzip.body" b.text)
  | .error e => checks := checks.push (fail "lean.echo.gzip.body" e)

  checks := checks.push (← fanOutRaw host port false)
  checks := checks.push (← fanOutRaw host port true)
  checks := checks.push (← collectGzip host port)

  -- Bidi Relay: multi-send + empty DATA END_STREAM halfClose (same framing as grpc-go).
  let stream ← Grpc.Channel.openStream ch serviceName "Relay"
  Grpc.Stream.StreamWriter.send stream.writer (Blob.encode { text := "one" })
  Grpc.Stream.StreamWriter.send stream.writer (Blob.encode { text := "two" })
  Grpc.Stream.StreamWriter.halfClose stream.writer
  let mut replies : Array String := #[]
  for _ in [:8] do
    match ← Grpc.Stream.StreamReader.recv? stream.reader with
    | none => break
    | some bytes =>
      let b ← IO.ofExcept (Blob.decode bytes)
      replies := replies.push b.text
  checks := checks.push (
    if replies == #["R:one", "R:two"] then pass "lean.relay.bidi_empty_halfclose" s!"{replies}"
    else fail "lean.relay.bidi_empty_halfclose" s!"{replies}")

  -- Deadline on SlowEcho
  let late ← Grpc.Channel.unary ch serviceName "SlowEcho" (Blob.encode { text := "x" }) {} (some "50m")
  checks := checks.push (expectCode "lean.slow.deadline" late.status.code .deadlineExceeded)

  -- RST → CANCELLED
  let c ← Grpc.Channel.get ch
  let headers : Array Hpack.HeaderField := #[
    Grpc.Metadata.methodPost,
    Grpc.Metadata.schemeHttp,
    ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
    Grpc.Metadata.path serviceName "SlowEcho",
    Grpc.Metadata.contentTypeGrpc,
    Grpc.Metadata.teTrailers,
    Grpc.Metadata.userAgent
  ]
  let sid ← H2.Client.startRequest c headers (Grpc.Message.encodeId (Blob.encode { text := "c" })) true
  H2.Client.resetStream c sid 0x8
  let resp ← H2.Client.awaitResponse c sid
  let st := trailerStatus resp.headers resp.trailers
  checks := checks.push (
    if st == "1" then pass "lean.rst.cancel" "CANCELLED"
    else fail "lean.rst.cancel" s!"grpc-status={st}")

  -- 415 bad content-type
  let c2 ← H2.Client.connectH2c host port
  let badHeaders : Array Hpack.HeaderField := #[
    Grpc.Metadata.methodPost,
    Grpc.Metadata.schemeHttp,
    ⟨Grpc.Metadata.ascii ":authority", Grpc.Metadata.ascii host⟩,
    Grpc.Metadata.path serviceName "Echo",
    ⟨Grpc.Metadata.ascii "content-type", Grpc.Metadata.ascii "text/plain"⟩,
    Grpc.Metadata.teTrailers
  ]
  let bad ← H2.Client.unary c2 badHeaders ByteArray.empty
  let mut http := ""
  for h in bad.headers do
    let (n, v) := headerAscii h
    if n == ":status" then http := v
  checks := checks.push (
    if http == "415" then pass "lean.content_type.415" "HTTP 415"
    else fail "lean.content_type.415" s!":status={http}")

  let mut failN : Nat := 0
  for c in checks do
    let mark := if c.ok then "PASS" else "FAIL"
    if !c.ok then failN := failN + 1
    if c.detail.isEmpty then IO.println s!"[{mark}] {c.name}"
    else IO.println s!"[{mark}] {c.name} — {c.detail}"
  if failN == 0 then
    IO.println s!"\nALL {checks.size} LEAN FRAMING CHECKS PASSED"
    return 0
  else
    IO.println s!"\n{failN}/{checks.size} LEAN FRAMING CHECKS FAILED"
    return 1
