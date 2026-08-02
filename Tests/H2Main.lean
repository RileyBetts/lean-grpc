/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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
  let reqBlock := Hpack.encodeHeadersIndexed #[
    ⟨ascii ":method", ascii "POST"⟩,
    ⟨ascii ":scheme", ascii "http"⟩,
    ⟨ascii ":path", ascii "/"⟩
  ]
  let stA := H2.ConnState.create
  let h1 := H2.Frame.headers 1 reqBlock false true
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

  -- responseHeaderFrames: HEADERS without END_STREAM when body/trailers follow
  let hdrs := H2.responseHeaderFrames 1
    #[⟨ascii ":status", ascii "200"⟩]
    false false false true
  if hdrs.size != 1 then throw (IO.userError s!"header frame count {hdrs.size}")
  if hdrs[0]!.type != .headers then throw (IO.userError "f0")
  if H2.Flags.has hdrs[0]!.flags H2.Flags.endStream then throw (IO.userError "f0 es")

  -- Flow control: peer INITIAL_WINDOW_SIZE=1 → first DATA length 1
  let st0 := H2.ConnState.create
  let setWin := H2.Frame.settings #[(.initialWindowSize, 1)]
  let (st1, _) ← IO.ofExcept (H2.handleFrame st0 setWin)
  let hReq := H2.Frame.headers 1 reqBlock true true
  let (st2, _) ← IO.ofExcept (H2.handleFrame st1 hReq)
  let (st3, dataFrames) := H2.queueSend st2 1 (ByteArray.mk #[0x6f, 0x6b]) #[] true
  if dataFrames.size != 1 then throw (IO.userError s!"data frames {dataFrames.size}")
  if dataFrames[0]!.payload.size != 1 then throw (IO.userError "expected 1-byte DATA")
  if H2.Flags.has dataFrames[0]!.flags H2.Flags.endStream then throw (IO.userError "unexpected ES")
  match st3.getStream 1 with
  | none => throw (IO.userError "stream gone")
  | some s =>
    if s.pendingSend.size != 1 then throw (IO.userError "pending not held")

  IO.println "h2Tests OK"
