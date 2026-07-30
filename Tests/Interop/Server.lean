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
    let (initialMd, trailingBin) := echoMd headers
    let respHeaders := Grpc.Metadata.http200 ++ initialMd
    let addTrailing (st : Grpc.Status) : Array Hpack.HeaderField :=
      let base := Grpc.Metadata.statusHeaders st
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
      let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray data))
      let req ← IO.ofExcept (Proto.SimpleRequest.decode (payloads.getD 0 ByteArray.empty))
      if let some st := req.responseStatus then
        let code := Grpc.StatusCode.ofUInt32 st.code
        return {
          headers := respHeaders
          trailers := addTrailing ⟨code, st.message⟩
          finished := true
        }
      let body := zeros req.responseSize.toNat
      let resp := Proto.SimpleResponse.encode {
        payloadBody := body
        username := if req.fillUsername then "lean" else ""
      }
      return {
        headers := respHeaders
        body := Grpc.Message.encodeId resp
        trailers := addTrailing .ok
        finished := true
      }
    | "/grpc.testing.TestService/StreamingOutputCall" =>
      if !endStream then return { finished := false }
      let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray data))
      let req ← IO.ofExcept (Proto.StreamingOutputCallRequest.decode (payloads.getD 0 ByteArray.empty))
      let mut out := ByteArray.empty
      for sz in req.responseParameters do
        let msg := Proto.StreamingOutputCallResponse.encode { payloadBody := zeros sz.toNat }
        out := Bytes.Pool.pushBytes out (Grpc.Message.encodeId msg)
      return {
        headers := respHeaders
        body := out
        trailers := addTrailing .ok
        finished := true
      }
    | "/grpc.testing.TestService/StreamingInputCall" =>
      if !endStream then return { finished := false }
      let payloads ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray data))
      let mut total : Nat := 0
      for p in payloads do
        let req ← IO.ofExcept (Proto.StreamingInputCallRequest.decode p)
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
      let mut out := ByteArray.empty
      for p in msgs do
        let req ← IO.ofExcept (Proto.StreamingOutputCallRequest.decode p)
        if let some st := req.responseStatus then
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
    | _ =>
      if !endStream then return { finished := false }
      return {
        headers := respHeaders
        trailers := addTrailing (.unimplemented s!"unknown {path}")
        finished := true
      }
  H2.Server.listen { host := "127.0.0.1", port } handler
