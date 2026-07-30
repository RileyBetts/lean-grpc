/-
Copyright (c) 2026 RileyBetts. All rights reserved.
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

/-- Encode with indexed static entries when possible. -/
def encodeHeadersIndexed (headers : Array HeaderField) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for h in headers do
      match findStaticExact h.name h.value with
      | some idx =>
        out := encodeInteger out 0x80 7 idx
      | none =>
        match findStaticName h.name with
        | some idx =>
          -- Literal without indexing — indexed name
          out := encodeInteger out 0x00 4 idx
          out := encodeInteger out 0x00 7 h.value.size
          out := Bytes.Pool.pushBytes out h.value
        | none =>
          out := encodeInteger out 0x00 4 0
          out := encodeInteger out 0x00 7 h.name.size
          out := Bytes.Pool.pushBytes out h.name
          out := encodeInteger out 0x00 7 h.value.size
          out := Bytes.Pool.pushBytes out h.value
    return out

/-- Decode a full header block. -/
def decodeHeaders (block : Bytes.Slice) (table : DynamicTable := .empty) :
    Except String (Array HeaderField × DynamicTable) := do
  let mut pos : Nat := 0
  let mut headers : Array HeaderField := #[]
  let mut table := table
  while pos < block.size do
    let b ← block.get? pos |>.elim (throw "truncated header") pure
    if (b &&& 128) != 0 then
      -- Indexed
      let (idx, pos') ← decodeInteger block pos 7
      pos := pos'
      let h ← table.get? idx |>.elim (throw s!"bad index {idx}") pure
      headers := headers.push h
    else if (b &&& 192) == 64 then
      -- Literal with incremental indexing
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
      -- Literal without indexing
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
      -- Never indexed
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
    else if (b &&& 224) == 32 then
      -- Dynamic table size update
      let (sz, pos') ← decodeInteger block pos 5
      pos := pos'
      table := DynamicTable.evict { table with maxSize := sz }
    else
      throw s!"unknown header representation at {pos}"
  return (headers, table)

end Hpack
