/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice

namespace Proto.WellKnown

/-- google.protobuf.Any (type_url + value). -/
structure AnyMsg where
  typeUrl : String := ""
  value : ByteArray := ByteArray.empty
  deriving Inhabited

def AnyMsg.encode (a : AnyMsg) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !a.typeUrl.isEmpty then acc := Wire.encodeString acc 1 a.typeUrl
    if !a.value.isEmpty then acc := Wire.encodeBytes acc 2 a.value
    return acc

def AnyMsg.decode (b : ByteArray) : Except String AnyMsg := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    typeUrl := (Wire.fieldString? fields 1).getD ""
    value := (Wire.fieldBytes? fields 2).getD ByteArray.empty
  }

/-- Minimal oneof tag helper: which field number was set (first match). -/
def oneofWhich (fields : Array Wire.Field) (candidates : Array Nat) : Option Nat :=
  Id.run do
    for n in candidates do
      for f in fields do
        if f.number == n then return some n
    return none

/-- Map entry: key (field 1 string) + value (field 2 bytes). -/
structure MapEntry where
  key : String := ""
  value : ByteArray := ByteArray.empty
  deriving Inhabited

def MapEntry.encode (e : MapEntry) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !e.key.isEmpty then acc := Wire.encodeString acc 1 e.key
    if !e.value.isEmpty then acc := Wire.encodeBytes acc 2 e.value
    return acc

def MapEntry.decode (b : ByteArray) : Except String MapEntry := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    key := (Wire.fieldString? fields 1).getD ""
    value := (Wire.fieldBytes? fields 2).getD ByteArray.empty
  }

/-- Decode repeated map entries (length-delimited messages on `field`). -/
def decodeMap (fields : Array Wire.Field) (field : Nat) : Except String (Array MapEntry) := do
  let mut out : Array MapEntry := #[]
  for nested in Wire.fieldBytesMany fields field do
    out := out.push (← MapEntry.decode nested)
  return out

/-- google.rpc.Status (code, message, details). -/
structure RpcStatus where
  code : Int32 := 0
  message : String := ""
  details : Array AnyMsg := #[]
  deriving Inhabited

def RpcStatus.encode (s : RpcStatus) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if s.code != 0 then
      -- protobuf int32 as zigzag-free varint (signed via UInt32 bit pattern)
      acc := Wire.encodeUInt32 acc 1 (s.code.toUInt32)
    if !s.message.isEmpty then acc := Wire.encodeString acc 2 s.message
    for d in s.details do
      acc := Wire.encodeBytes acc 3 (AnyMsg.encode d)
    return acc

def RpcStatus.decode (b : ByteArray) : Except String RpcStatus := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let mut details : Array AnyMsg := #[]
  for nested in Wire.fieldBytesMany fields 3 do
    details := details.push (← AnyMsg.decode nested)
  let codeU := (Wire.fieldUInt32? fields 1).getD 0
  return {
    code := codeU.toInt32
    message := (Wire.fieldString? fields 2).getD ""
    details
  }

end Proto.WellKnown
