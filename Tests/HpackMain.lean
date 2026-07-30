/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Hpack
import Bytes.Slice

private def ascii (s : String) : ByteArray :=
  ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray

def main : IO Unit := do
  let headers : Array Hpack.HeaderField := #[
    ⟨ascii "custom-key", ascii "custom-header"⟩
  ]
  let enc := Hpack.encodeHeaders headers
  match Hpack.decodeHeaders (Bytes.Slice.ofByteArray enc) with
  | .error e => throw (IO.userError e)
  | .ok (decoded, _) =>
    if decoded.size != 1 then throw (IO.userError "count")
    if decoded[0]!.name != headers[0]!.name then throw (IO.userError "name")
    if decoded[0]!.value != headers[0]!.value then throw (IO.userError "value")
  let enc2 := Hpack.encodeHeadersIndexed #[⟨ascii ":method", ascii "POST"⟩]
  match Hpack.decodeHeaders (Bytes.Slice.ofByteArray enc2) with
  | .error e => throw (IO.userError e)
  | .ok (d, _) =>
    if d.size != 1 then throw (IO.userError "idx count")
  if Hpack.staticTable.size != 61 then throw (IO.userError "static size")
  IO.println "hpackTests OK"
