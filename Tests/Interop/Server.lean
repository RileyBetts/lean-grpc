/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto
import H2
import Hpack
import Bytes.Slice
import Bytes.Pool

private def headerAscii (h : Hpack.HeaderField) : String × String :=
  (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
   String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))

private def zeros (n : Nat) : ByteArray :=
  Id.run do
    let mut b := ByteArray.empty
    for _ in [:n] do b := b.push 0
    return b

private def echoMd (headers : Array Hpack.HeaderField) :
    Array Hpack.HeaderField × Option Hpack.HeaderField :=
  Id.run do
    let mut initial : Array Hpack.HeaderField := #[]
    let mut trailing : Option Hpack.HeaderField := none
    for h in headers do
      let (n, v) := headerAscii h
      if n == "x-grpc-test-echo-initial" then
        initial := initial.push ⟨Grpc.Metadata.ascii n, Grpc.Metadata.ascii v⟩
      if n == "x-grpc-test-echo-trailing-bin" then
        trailing := some h
    return (initial, trailing)

def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "10000").toNat?.getD 10000 |>.toUInt16
  let handler : H2.StreamHandler := fun _streamId headers data endStream headersSent => do
    let path :=
      Id.run do
        for h in headers do
          let (n, v) := headerAscii h
          if n == ":path" then return v
        return ""
    let acceptEnc :=
      Id.run do
        for h in headers do
          let (n, v) := headerAscii h
          if n == "grpc-accept-encoding" then return v
        return "identity"
    -- Only compress when a case explicitly requests it (response_compressed) or
    -- when we later set outAlg. Default identity avoids surprising multi-message
    -- parse issues with peers that probe accept-encoding on every unary.
    let _ := acceptEnc
    let (initialMd, trailingBin) := echoMd headers
    let authHdr :=
      Id.run do
        for h in headers do
          let (n, v) := headerAscii h
          if n == "authorization" then return v
        return ""
    let mut respHeaders := Grpc.Metadata.http200 ++ initialMd
    let addTrailing (st : Grpc.Status) (extra : Array Hpack.HeaderField := #[]) :
        Array Hpack.HeaderField :=
      let base := Grpc.Metadata.statusHeaders st ++ extra
      match trailingBin with
      | some h => base.push h
      | none => base

    match path with
    | "/grpc.testing.TestService/EmptyCall" =>
      if !endStream then return { finished := false }
      return {
        headers := respHeaders
        body := Grpc.Message.encodeId ByteArray.empty
        trailers := addTrailing .ok
        finished := true
      }
    | "/grpc.testing.TestService/UnaryCall" =>
      if !endStream then return { finished := false }
      let flagged ←
        match ← Grpc.Message.decodeAllWithFlagsIO (Bytes.Slice.ofByteArray data) with
        | .ok ps => pure ps
        | .error e => throw (IO.userError e)
      let compressedFlag := (flagged.getD 0 (false, ByteArray.empty)).1
      let req ← IO.ofExcept (Proto.SimpleRequest.decode (flagged.getD 0 (false, ByteArray.empty)).2)
      if let some expect := req.expectCompressed then
        if expect != compressedFlag then
          return {
            headers := respHeaders
            trailers := addTrailing (.invalidArgument "expect_compressed mismatch")
            finished := true
          }
      if let some st := req.responseStatus then
        let code := Grpc.StatusCode.ofUInt32 st.code
        return {
          headers := respHeaders
          trailers := addTrailing ⟨code, st.message⟩
          finished := true
        }
      let body := zeros req.responseSize.toNat
      let username :=
        if req.fillUsername then
          if authHdr.isEmpty then "lean"
          else Grpc.Jwt.usernameFromAuthorization authHdr
        else ""
      let envScope ← IO.getEnv "LEAN_GRPC_OAUTH_SCOPE"
      let oauthScope :=
        if req.fillOauthScope then
          envScope.getD "https://www.googleapis.com/auth/xapi.zoo"
        else ""
      let orcaExtra :=
        if req.orcaPerQueryReport.isEmpty then #[]
        else
          match Grpc.Orca.Report.decode req.orcaPerQueryReport with
          | .ok r => #[Grpc.Orca.trailerField r]
          | .error _ =>
            -- Pass through opaque bytes as ORCA trailer.
            #[⟨Grpc.Metadata.ascii Grpc.Orca.trailerKey,
               Grpc.Metadata.ascii (Grpc.Metadata.base64Encode req.orcaPerQueryReport)⟩]
      let resp := Proto.SimpleResponse.encode {
        payloadBody := body
        username
        oauthScope
      }
      let outAlg :=
        match req.responseCompressed with
        | some true => Grpc.Compression.Algorithm.gzip
        | _ => Grpc.Compression.Algorithm.identity
      let mut hdrs := respHeaders
      if outAlg != .identity then
        hdrs := hdrs.push (Grpc.Metadata.grpcEncoding outAlg.name)
      return {
        headers := hdrs
        body := ← Grpc.Message.encodeIO resp outAlg
        trailers := addTrailing .ok orcaExtra
        finished := true
      }
    | "/grpc.testing.TestService/StreamingOutputCall" =>
      if !endStream then return { finished := false }
      let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray data))
      let req ← IO.ofExcept (Proto.StreamingOutputCallRequest.decode (payloads.getD 0 ByteArray.empty))
      let outAlg :=
        match req.responseCompressed with
        | some true => Grpc.Compression.Algorithm.gzip
        | _ => Grpc.Compression.Algorithm.identity
      let mut hdrs := respHeaders
      if outAlg != .identity then
        hdrs := hdrs.push (Grpc.Metadata.grpcEncoding outAlg.name)
      let mut out := ByteArray.empty
      for sz in req.responseParameters do
        let msg := Proto.StreamingOutputCallResponse.encode { payloadBody := zeros sz.toNat }
        out := Bytes.Pool.pushBytes out (← Grpc.Message.encodeIO msg outAlg)
      return {
        headers := hdrs
        body := out
        trailers := addTrailing .ok
        finished := true
      }
    | "/grpc.testing.TestService/StreamingInputCall" =>
      if !endStream then return { finished := false }
      let flagged ←
        match ← Grpc.Message.decodeAllWithFlagsIO (Bytes.Slice.ofByteArray data) with
        | .ok ps => pure ps
        | .error e => throw (IO.userError e)
      let mut total : Nat := 0
      for (compressedFlag, p) in flagged do
        let req ← IO.ofExcept (Proto.StreamingInputCallRequest.decode p)
        if let some expect := req.expectCompressed then
          if expect != compressedFlag then
            return {
              headers := respHeaders
              trailers := addTrailing (.invalidArgument "expect_compressed mismatch")
              finished := true
            }
        total := total + req.payloadBody.size
      let resp := Proto.StreamingInputCallResponse.encode { aggregatedPayloadSize := total.toUInt32 }
      return {
        headers := respHeaders
        body := Grpc.Message.encodeId resp
        trailers := addTrailing .ok
        finished := true
      }
    | "/grpc.testing.TestService/FullDuplexCall"
    | "/grpc.testing.TestService/HalfDuplexCall" =>
      let (msgs, _rest) ← IO.ofExcept (Grpc.Stream.decodeAvailable data)
      if msgs.isEmpty && !endStream then
        return { finished := false }
      -- timeout_on_sleeping_server: sleep when asked via responseStatus message "sleep"
      for p in msgs do
        let req ← IO.ofExcept (Proto.StreamingOutputCallRequest.decode p)
        if let some st := req.responseStatus then
          if st.message == "sleep" then
            -- Longer than typical interop client deadlines (e.g. 100ms).
            IO.sleep 2000
      let mut out := ByteArray.empty
      for p in msgs do
        let req ← IO.ofExcept (Proto.StreamingOutputCallRequest.decode p)
        if let some st := req.responseStatus then
          if st.message != "sleep" then
            let code := Grpc.StatusCode.ofUInt32 st.code
            return {
              headers := if headersSent then #[] else respHeaders
              trailers := addTrailing ⟨code, st.message⟩
              finished := true
            }
        for sz in req.responseParameters do
          let msg := Proto.StreamingOutputCallResponse.encode { payloadBody := zeros sz.toNat }
          out := Bytes.Pool.pushBytes out (Grpc.Message.encodeId msg)
      if endStream then
        return {
          headers := if headersSent then #[] else respHeaders
          body := out
          trailers := addTrailing .ok
          finished := true
        }
      else
        return {
          headers := if headersSent then #[] else respHeaders
          body := out
          finished := false
        }
    | "/grpc.testing.UnimplementedService/UnimplementedCall" =>
      if !endStream then return { finished := false }
      return {
        headers := respHeaders
        trailers := addTrailing (.unimplemented "unimplemented")
        finished := true
      }
    | _ =>
      if !endStream then return { finished := false }
      return {
        headers := respHeaders
        trailers := addTrailing (.unimplemented s!"unknown {path}")
        finished := true
      }
  H2.Server.listen { host := "127.0.0.1", port } handler
