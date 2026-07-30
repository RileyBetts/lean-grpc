/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes

def assertBEq {α} [BEq α] [Repr α] (name : String) (got expected : α) : IO Unit := do
  if got == expected then
    IO.println s!"ok {name}"
  else
    throw (IO.userError s!"FAIL {name}: got {repr got} expected {repr expected}")

def main : IO Unit := do
  let b := ByteArray.mk #[1, 2, 3, 4, 5]
  let s := Bytes.Slice.ofByteArray b
  assertBEq "size" s.size 5
  let sub := s.sub 1 3
  assertBEq "subsize" sub.size 3
  assertBEq "sub0" (sub.get! 0) 2
  match Bytes.BE.readU32 s 1 with
  | none => throw (IO.userError "readU32")
  | some v => assertBEq "be32" v 0x02030405
  let (p, _b2) := Bytes.Pool.acquire Bytes.Pool.empty 0
  let p := Bytes.Pool.release p (ByteArray.mk #[9])
  assertBEq "pool" p.free.size 1
  IO.println "bytesTests OK"
