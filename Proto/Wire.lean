/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.Pool

namespace Proto
namespace Wire

inductive WireType where
  | varint | fixed64 | lengthDelimited | startGroup | endGroup | fixed32
  deriving BEq, Inhabited

def WireType.toNat : WireType → Nat
  | .varint => 0 | .fixed64 => 1 | .lengthDelimited => 2
  | .startGroup => 3 | .endGroup => 4 | .fixed32 => 5

def encodeVarint (acc : ByteArray) (v : UInt64) : ByteArray :=
  Id.run do
    let mut out := acc
    let mut x := v
    while true do
      if x < 0x80 then
        return out.push x.toUInt8
      out := out.push ((x.toUInt8 &&& 0x7f) ||| 0x80)
      x := x >>> 7
    return out

def decodeVarint (s : Bytes.Slice) (off : Nat) : Except String (UInt64 × Nat) := do
  let mut result : UInt64 := 0
  let mut shift : UInt64 := 0
  let mut pos := off
  for _ in [:10] do
    let b ← s.get? pos |>.elim (throw "trunc varint") pure
    pos := pos + 1
    result := result ||| ((b.toUInt64 &&& 0x7f) <<< shift)
    if (b &&& 0x80) == 0 then return (result, pos)
    shift := shift + 7
  throw "varint overflow"

def encodeKey (acc : ByteArray) (field : Nat) (wt : WireType) : ByteArray :=
  encodeVarint acc (((field <<< 3) + wt.toNat).toUInt64)

def encodeString (acc : ByteArray) (field : Nat) (s : String) : ByteArray :=
  let bytes := ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray
  let acc := encodeKey acc field .lengthDelimited
  let acc := encodeVarint acc bytes.size.toUInt64
  Bytes.Pool.pushBytes acc bytes

def encodeBytes (acc : ByteArray) (field : Nat) (b : ByteArray) : ByteArray :=
  let acc := encodeKey acc field .lengthDelimited
  let acc := encodeVarint acc b.size.toUInt64
  Bytes.Pool.pushBytes acc b

def encodeUInt32 (acc : ByteArray) (field : Nat) (v : UInt32) : ByteArray :=
  encodeVarint (encodeKey acc field .varint) v.toUInt64

def encodeBool (acc : ByteArray) (field : Nat) (v : Bool) : ByteArray :=
  encodeUInt32 acc field (if v then 1 else 0)

structure Field where
  number : Nat
  wireType : WireType
  payload : ByteArray
  deriving Inhabited

def decodeFields (s : Bytes.Slice) : Except String (Array Field) := do
  let mut pos : Nat := 0
  let mut out : Array Field := #[]
  while pos < s.size do
    let (key, pos1) ← decodeVarint s pos
    pos := pos1
    let fn := (key >>> 3).toNat
    let wt := match (key &&& 7).toNat with
      | 0 => WireType.varint | 1 => .fixed64 | 2 => .lengthDelimited
      | 3 => .startGroup | 4 => .endGroup | 5 => .fixed32 | _ => .varint
    match wt with
    | .varint =>
      let (v, pos2) ← decodeVarint s pos
      pos := pos2
      out := out.push ⟨fn, wt, encodeVarint ByteArray.empty v⟩
    | .fixed64 =>
      if pos + 8 > s.size then throw "trunc f64"
      out := out.push ⟨fn, wt, (s.sub pos 8).toByteArray⟩
      pos := pos + 8
    | .fixed32 =>
      if pos + 4 > s.size then throw "trunc f32"
      out := out.push ⟨fn, wt, (s.sub pos 4).toByteArray⟩
      pos := pos + 4
    | .lengthDelimited =>
      let (len, pos2) ← decodeVarint s pos
      pos := pos2
      let n := len.toNat
      if pos + n > s.size then throw "trunc ld"
      out := out.push ⟨fn, wt, (s.sub pos n).toByteArray⟩
      pos := pos + n
    | .startGroup | .endGroup =>
      throw "groups not supported in minimal codec"
  return out

def fieldString? (fields : Array Field) (n : Nat) : Option String :=
  Id.run do
    for f in fields do
      if f.number == n && f.wireType == .lengthDelimited then
        return some (String.ofList (f.payload.toList.map (fun b => Char.ofNat b.toNat)))
    return none

def fieldUInt32? (fields : Array Field) (n : Nat) : Option UInt32 :=
  Id.run do
    for f in fields do
      if f.number == n && f.wireType == .varint then
        match decodeVarint (Bytes.Slice.ofByteArray f.payload) 0 with
        | .ok (v, _) => return some v.toUInt32
        | .error _ => pure ()
    return none

def fieldBytes? (fields : Array Field) (n : Nat) : Option ByteArray :=
  Id.run do
    for f in fields do
      if f.number == n && f.wireType == .lengthDelimited then
        return some f.payload
    return none

end Wire
end Proto
