/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Bytes.Slice

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
  IO.println "h2Tests OK"
