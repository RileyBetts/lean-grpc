/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Proto.Wire

namespace Proto

/-- helloworld.HelloRequest { string name = 1; } -/
structure HelloRequest where
  name : String := ""
  deriving Inhabited, BEq

/-- helloworld.HelloReply { string message = 1; } -/
structure HelloReply where
  message : String := ""
  deriving Inhabited, BEq

def HelloRequest.encode (r : HelloRequest) : ByteArray :=
  if r.name.isEmpty then ByteArray.empty
  else Wire.encodeString ByteArray.empty 1 r.name

def HelloRequest.decode (b : ByteArray) : Except String HelloRequest := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return { name := (Wire.fieldString? fields 1).getD "" }

def HelloReply.encode (r : HelloReply) : ByteArray :=
  if r.message.isEmpty then ByteArray.empty
  else Wire.encodeString ByteArray.empty 1 r.message

def HelloReply.decode (b : ByteArray) : Except String HelloReply := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return { message := (Wire.fieldString? fields 1).getD "" }

/-- Interop SimpleRequest subset. -/
structure SimpleRequest where
  responseSize : UInt32 := 0
  fillUsername : Bool := false
  deriving Inhabited

def SimpleRequest.encode (r : SimpleRequest) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if r.responseSize != 0 then
      acc := Wire.encodeUInt32 acc 7 r.responseSize  -- response_size = 7 in grpc interop
    if r.fillUsername then
      acc := Wire.encodeBool acc 4 true
    return acc

def SimpleRequest.decode (b : ByteArray) : Except String SimpleRequest := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    responseSize := (Wire.fieldUInt32? fields 7).getD 0
    fillUsername := (Wire.fieldUInt32? fields 4).getD 0 != 0
  }

structure SimpleResponse where
  username : String := ""
  payloadBody : ByteArray := ByteArray.empty
  deriving Inhabited

def SimpleResponse.encode (r : SimpleResponse) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.payloadBody.isEmpty then
      -- payload = 1, body = nested field 2 — simplified: field 2 bytes directly for tests
      acc := Wire.encodeBytes acc 2 r.payloadBody
    if !r.username.isEmpty then
      acc := Wire.encodeString acc 3 r.username
    return acc

def SimpleResponse.decode (b : ByteArray) : Except String SimpleResponse := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    username := (Wire.fieldString? fields 3).getD ""
    payloadBody := (Wire.fieldBytes? fields 2).getD ByteArray.empty
  }

end Proto
