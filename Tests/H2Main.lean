/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Bytes.Slice
import Bytes.Pool
import Hpack

private def ascii (s : String) : ByteArray :=
  ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray

def main : IO Unit := do
  let f := H2.Frame.settings #[(.maxFrameSize, 16384)]
  let enc := H2.Frame.encode f
  match H2.Frame.decode (Bytes.Slice.ofByteArray enc) with
  | .error e => throw (IO.userError e)
  | .ok (f', n) =>
    if n != enc.size then throw (IO.userError "size")
    if f'.type != .settings then throw (IO.userError "type")
  let st := H2.ConnState.create
  let (st, outs) ← IO.ofExcept (H2.handleFrame st f)
  if outs.size != 1 then throw (IO.userError "expected SETTINGS ACK")
  if outs[0]!.type != .settings then throw (IO.userError "ack type")
  if st.wentAway then throw (IO.userError "unexpected goaway")
  if H2.clientPreface.size != 24 then throw (IO.userError "preface")

  -- Padded + priority HEADERS payload stripping
  let block := Hpack.encodeHeadersIndexed #[⟨ascii ":method", ascii "POST"⟩]
  let mut padded := ByteArray.empty
  padded := padded.push 2
  padded := Bytes.Pool.pushBytes padded (ByteArray.mk #[0,0,0,0,42])
  padded := Bytes.Pool.pushBytes padded block
  padded := padded.push 0xab
  padded := padded.push 0xcd
  let flags := H2.Flags.union H2.Flags.padded H2.Flags.priority
  let stripped ← IO.ofExcept (H2.Frame.stripHeaderPayload flags padded)
  if stripped != block then throw (IO.userError "strip mismatch")

  -- Trailers path: first HEADERS then second HEADERS with END_STREAM
  let stA := H2.ConnState.create
  let h1 := H2.Frame.headers 1 block false true
  let (stB, _) ← IO.ofExcept (H2.handleFrame stA h1)
  let trBlock := Hpack.encodeHeadersIndexed #[⟨ascii "grpc-status", ascii "0"⟩]
  let h2 := H2.Frame.headers 1 trBlock true true
  let (stC, _) ← IO.ofExcept (H2.handleFrame stB h2)
  match stC.getStream 1 with
  | none => throw (IO.userError "no stream")
  | some s =>
    if !s.gotHeaders then throw (IO.userError "gotHeaders")
    if !s.endTrailers then throw (IO.userError "endTrailers")
    if !s.endStreamRemote then throw (IO.userError "endStream")
    if s.trailersBuf.isEmpty then throw (IO.userError "empty trailers buf")

  -- responseFrames shape: headers + data + trailers
  let frames := H2.responseFrames 1
    #[⟨ascii ":status", ascii "200"⟩]
    (ByteArray.mk #[1,2,3])
    #[⟨ascii "grpc-status", ascii "0"⟩]
    16384 false true
  if frames.size < 3 then throw (IO.userError s!"frame count {frames.size}")
  if frames[0]!.type != .headers then throw (IO.userError "f0")
  if H2.Flags.has frames[0]!.flags H2.Flags.endStream then throw (IO.userError "f0 es")
  if frames[frames.size - 1]!.type != .headers then throw (IO.userError "last")
  if !(H2.Flags.has frames[frames.size - 1]!.flags H2.Flags.endStream) then
    throw (IO.userError "trailers need ES")

  IO.println "h2Tests OK"
