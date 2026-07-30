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

/-- grpc.testing.EchoStatus -/
structure EchoStatus where
  code : UInt32 := 0
  message : String := ""
  deriving Inhabited

def EchoStatus.encode (s : EchoStatus) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if s.code != 0 then acc := Wire.encodeUInt32 acc 1 s.code
    if !s.message.isEmpty then acc := Wire.encodeString acc 2 s.message
    return acc

def EchoStatus.decode (b : ByteArray) : Except String EchoStatus := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    code := (Wire.fieldUInt32? fields 1).getD 0
    message := (Wire.fieldString? fields 2).getD ""
  }

/-- grpc.testing.Payload { PayloadType type = 1; bytes body = 2; } -/
structure Payload where
  body : ByteArray := ByteArray.empty
  deriving Inhabited

def Payload.encode (p : Payload) : ByteArray :=
  if p.body.isEmpty then ByteArray.empty
  else Wire.encodeBytes ByteArray.empty 2 p.body

def Payload.decode (b : ByteArray) : Except String Payload := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return { body := (Wire.fieldBytes? fields 2).getD ByteArray.empty }

/-- Interop SimpleRequest (subset of grpc.testing.SimpleRequest). -/
structure SimpleRequest where
  responseSize : UInt32 := 0
  fillUsername : Bool := false
  responseStatus : Option EchoStatus := none
  payloadBody : ByteArray := ByteArray.empty
  deriving Inhabited

def SimpleRequest.encode (r : SimpleRequest) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    -- grpc.testing.SimpleRequest: response_size = 2, payload = 3, fill_username = 4,
    -- response_status = 8
    if r.responseSize != 0 then
      acc := Wire.encodeUInt32 acc 2 r.responseSize
    if !r.payloadBody.isEmpty then
      acc := Wire.encodeBytes acc 3 (Payload.encode { body := r.payloadBody })
    if r.fillUsername then
      acc := Wire.encodeBool acc 4 true
    -- response_status = 7 in grpc.testing.SimpleRequest
    if let some st := r.responseStatus then
      acc := Wire.encodeBytes acc 7 (EchoStatus.encode st)
    return acc

def SimpleRequest.decode (b : ByteArray) : Except String SimpleRequest := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let payloadBytes := (Wire.fieldBytes? fields 3).getD ByteArray.empty
  let payload ←
    if payloadBytes.isEmpty then pure ByteArray.empty
    else do
      let p ← Payload.decode payloadBytes
      pure p.body
  let statusBytes := Wire.fieldBytes? fields 7
  let responseStatus ←
    match statusBytes with
    | none => pure none
    | some sb => some <$> EchoStatus.decode sb
  return {
    responseSize := (Wire.fieldUInt32? fields 2).getD 0
    fillUsername := (Wire.fieldUInt32? fields 4).getD 0 != 0
    responseStatus
    payloadBody := payload
  }

structure SimpleResponse where
  username : String := ""
  payloadBody : ByteArray := ByteArray.empty
  deriving Inhabited

def SimpleResponse.encode (r : SimpleResponse) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.payloadBody.isEmpty then
      acc := Wire.encodeBytes acc 1 (Payload.encode { body := r.payloadBody })
    if !r.username.isEmpty then
      acc := Wire.encodeString acc 2 r.username
    return acc

def SimpleResponse.decode (b : ByteArray) : Except String SimpleResponse := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let payloadBytes := (Wire.fieldBytes? fields 1).getD ByteArray.empty
  let payload ←
    if payloadBytes.isEmpty then pure ByteArray.empty
    else do
      let p ← Payload.decode payloadBytes
      pure p.body
  return {
    username := (Wire.fieldString? fields 2).getD ""
    payloadBody := payload
  }

/-- Streaming output call request (subset). -/
structure StreamingOutputCallRequest where
  responseParameters : Array UInt32 := #[]  -- sizes
  responseStatus : Option EchoStatus := none
  deriving Inhabited

def StreamingOutputCallRequest.encode (r : StreamingOutputCallRequest) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    for sz in r.responseParameters do
      -- ResponseParameters { size = 1; } nested in field 2
      let inner := Wire.encodeUInt32 ByteArray.empty 1 sz
      acc := Wire.encodeBytes acc 2 inner
    if let some st := r.responseStatus then
      acc := Wire.encodeBytes acc 7 (EchoStatus.encode st)
    return acc

def StreamingOutputCallRequest.decode (b : ByteArray) : Except String StreamingOutputCallRequest := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let mut sizes : Array UInt32 := #[]
  for f in fields do
    if f.number == 2 && f.wireType == .lengthDelimited then
      let inner ← Wire.decodeFields (Bytes.Slice.ofByteArray f.payload)
      sizes := sizes.push ((Wire.fieldUInt32? inner 1).getD 0)
  let responseStatus ←
    match Wire.fieldBytes? fields 7 with
    | none => pure none
    | some sb => some <$> EchoStatus.decode sb
  return { responseParameters := sizes, responseStatus }

structure StreamingOutputCallResponse where
  payloadBody : ByteArray := ByteArray.empty
  deriving Inhabited

def StreamingOutputCallResponse.encode (r : StreamingOutputCallResponse) : ByteArray :=
  if r.payloadBody.isEmpty then ByteArray.empty
  else Wire.encodeBytes ByteArray.empty 1 (Payload.encode { body := r.payloadBody })

def StreamingOutputCallResponse.decode (b : ByteArray) : Except String StreamingOutputCallResponse := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let payloadBytes := (Wire.fieldBytes? fields 1).getD ByteArray.empty
  let payload ←
    if payloadBytes.isEmpty then pure ByteArray.empty
    else do
      let p ← Payload.decode payloadBytes
      pure p.body
  return { payloadBody := payload }

structure StreamingInputCallRequest where
  payloadBody : ByteArray := ByteArray.empty
  deriving Inhabited

def StreamingInputCallRequest.encode (r : StreamingInputCallRequest) : ByteArray :=
  if r.payloadBody.isEmpty then ByteArray.empty
  else Wire.encodeBytes ByteArray.empty 1 (Payload.encode { body := r.payloadBody })

def StreamingInputCallRequest.decode (b : ByteArray) : Except String StreamingInputCallRequest := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let payloadBytes := (Wire.fieldBytes? fields 1).getD ByteArray.empty
  let payload ←
    if payloadBytes.isEmpty then pure ByteArray.empty
    else do
      let p ← Payload.decode payloadBytes
      pure p.body
  return { payloadBody := payload }

structure StreamingInputCallResponse where
  aggregatedPayloadSize : UInt32 := 0
  deriving Inhabited

def StreamingInputCallResponse.encode (r : StreamingInputCallResponse) : ByteArray :=
  if r.aggregatedPayloadSize == 0 then ByteArray.empty
  else Wire.encodeUInt32 ByteArray.empty 1 r.aggregatedPayloadSize

def StreamingInputCallResponse.decode (b : ByteArray) : Except String StreamingInputCallResponse := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return { aggregatedPayloadSize := (Wire.fieldUInt32? fields 1).getD 0 }

end Proto
