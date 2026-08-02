/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Hpack.StaticTable
import Hpack.Decode
import Hpack.Huffman

namespace Hpack

/-- Encode a header list using literal without indexing (never indexed), raw strings.
    Interoperable and avoids Huffman complexity on the encode path. -/
def encodeHeaders (headers : Array HeaderField) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for h in headers do
      -- Literal Header Field never Indexed — New Name (0b0001xxxx with name len)
      -- Use 0000 0000 pattern for new name never-indexed: 0x10 | name...
      -- RFC: Never Indexed Literal = 0001xxxx
      out := encodeInteger out 0x10 4 0  -- new name (name index 0)
      out := encodeInteger out 0x00 7 h.name.size
      out := Bytes.Pool.pushBytes out h.name
      out := encodeInteger out 0x00 7 h.value.size
      out := Bytes.Pool.pushBytes out h.value
    return out

private def encodeStringLiteral (acc : ByteArray) (data : ByteArray) (huffman : Bool) : ByteArray :=
  if huffman then
    let coded := Huffman.encode (Bytes.Slice.ofByteArray data)
    let acc := encodeInteger acc 0x80 7 coded.size
    Bytes.Pool.pushBytes acc coded
  else
    let acc := encodeInteger acc 0x00 7 data.size
    Bytes.Pool.pushBytes acc data

/-- Encode with indexed static entries when possible. -/
def encodeHeadersIndexed (headers : Array HeaderField) (huffman : Bool := false) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for h in headers do
      match findStaticExact h.name h.value with
      | some idx =>
        out := encodeInteger out 0x80 7 idx
      | none =>
        match findStaticName h.name with
        | some idx =>
          out := encodeInteger out 0x00 4 idx
          out := encodeStringLiteral out h.value huffman
        | none =>
          out := encodeInteger out 0x00 4 0
          out := encodeStringLiteral out h.name huffman
          out := encodeStringLiteral out h.value huffman
    return out

/-- Encode with incremental indexing into the dynamic table. -/
def encodeHeadersDynamic (headers : Array HeaderField) (table : DynamicTable)
    (huffman : Bool := false) : ByteArray × DynamicTable :=
  Id.run do
    let mut out := ByteArray.empty
    let mut table := table
    for h in headers do
      match findStaticExact h.name h.value with
      | some idx =>
        out := encodeInteger out 0x80 7 idx
      | none =>
        match table.entries.findIdx? (fun e => e.name == h.name && e.value == h.value) with
        | some dynIdx =>
          let idx := staticTable.size + 1 + dynIdx
          out := encodeInteger out 0x80 7 idx
        | none =>
          match findStaticName h.name with
          | some idx =>
            out := encodeInteger out 0x40 6 idx
            out := encodeStringLiteral out h.value huffman
          | none =>
            out := encodeInteger out 0x40 6 0
            out := encodeStringLiteral out h.name huffman
            out := encodeStringLiteral out h.value huffman
          table := table.insert h
    return (out, table)

/-- Decode a full header block.
    Dynamic table size updates are only legal at the start of the block.
    Indexed representation with index 0 is a compression error. -/
def decodeHeaders (block : Bytes.Slice) (table : DynamicTable := .empty)
    (maxTableSize : Nat := 4096) :
    Except String (Array HeaderField × DynamicTable) := do
  let mut pos : Nat := 0
  let mut headers : Array HeaderField := #[]
  let mut table := table
  let mut seenField := false
  while pos < block.size do
    let b ← block.get? pos |>.elim (throw "truncated header") pure
    if (b &&& 224) == 32 then
      -- Dynamic table size update (must precede any field representation)
      if seenField then throw "table size update after fields"
      let (sz, pos') ← decodeInteger block pos 5
      pos := pos'
      if sz > maxTableSize then throw "table size update too large"
      table := DynamicTable.evict { table with maxSize := sz }
    else if (b &&& 128) != 0 then
      seenField := true
      let (idx, pos') ← decodeInteger block pos 7
      pos := pos'
      if idx == 0 then throw "indexed index 0"
      let h ← table.get? idx |>.elim (throw s!"bad index {idx}") pure
      headers := headers.push h
    else if (b &&& 192) == 64 then
      seenField := true
      let (nameIdx, pos') ← decodeInteger block pos 6
      pos := pos'
      let (name, pos2) ←
        if nameIdx == 0 then decodeString block pos
        else do
          let h ← table.get? nameIdx |>.elim (throw "bad name idx") pure
          pure (h.name, pos)
      pos := pos2
      let (value, pos3) ← decodeString block pos
      pos := pos3
      let field := ⟨name, value⟩
      table := table.insert field
      headers := headers.push field
    else if (b &&& 240) == 0 then
      seenField := true
      let (nameIdx, pos') ← decodeInteger block pos 4
      pos := pos'
      let (name, pos2) ←
        if nameIdx == 0 then decodeString block pos
        else do
          let h ← table.get? nameIdx |>.elim (throw "bad name idx") pure
          pure (h.name, pos)
      pos := pos2
      let (value, pos3) ← decodeString block pos
      pos := pos3
      headers := headers.push ⟨name, value⟩
    else if (b &&& 240) == 16 then
      seenField := true
      let (nameIdx, pos') ← decodeInteger block pos 4
      pos := pos'
      let (name, pos2) ←
        if nameIdx == 0 then decodeString block pos
        else do
          let h ← table.get? nameIdx |>.elim (throw "bad name idx") pure
          pure (h.name, pos)
      pos := pos2
      let (value, pos3) ← decodeString block pos
      pos := pos3
      headers := headers.push ⟨name, value⟩
    else
      throw s!"unknown header representation at {pos}"
  return (headers, table)

end Hpack
