/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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

  -- Huffman round-trip (RFC 7541 style)
  let sample := ascii "www.example.com"
  let huff := Hpack.Huffman.encode (Bytes.Slice.ofByteArray sample)
  match Hpack.Huffman.decode (Bytes.Slice.ofByteArray huff) with
  | .error _ => throw (IO.userError "huffman decode")
  | .ok raw =>
    if raw != sample then throw (IO.userError "huffman roundtrip")

  let encH := Hpack.encodeHeadersIndexed headers (huffman := true)
  match Hpack.decodeHeaders (Bytes.Slice.ofByteArray encH) with
  | .error e => throw (IO.userError e)
  | .ok (d, _) =>
    if d.size != 1 then throw (IO.userError "huff hdr count")
    if d[0]!.value != headers[0]!.value then throw (IO.userError "huff value")

  -- Dynamic table encode
  let (encD, table) := Hpack.encodeHeadersDynamic headers .empty
  match Hpack.decodeHeaders (Bytes.Slice.ofByteArray encD) with
  | .error e => throw (IO.userError e)
  | .ok (d, table') =>
    if d.size != 1 then throw (IO.userError "dyn count")
    if table.size == 0 then throw (IO.userError "dyn insert")
    if table'.size == 0 then throw (IO.userError "dyn decode insert")

  IO.println "hpackTests OK"
