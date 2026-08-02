/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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

/-- grpc.testing.PayloadType enum. -/
inductive PayloadType where
  | compressable
  | uncompressable
  | random
  deriving BEq, Inhabited

def PayloadType.toUInt32 : PayloadType → UInt32
  | .compressable => 0
  | .uncompressable => 1
  | .random => 2

def PayloadType.ofUInt32 : UInt32 → PayloadType
  | 1 => .uncompressable
  | 2 => .random
  | _ => .compressable

/-- grpc.testing.Payload { PayloadType type = 1; bytes body = 2; } -/
structure Payload where
  type : PayloadType := .compressable
  body : ByteArray := ByteArray.empty
  deriving Inhabited

def Payload.encode (p : Payload) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if p.type != .compressable then
      acc := Wire.encodeEnum acc 1 p.type.toUInt32
    if !p.body.isEmpty then
      acc := Wire.encodeBytes acc 2 p.body
    return acc

def Payload.decode (b : ByteArray) : Except String Payload := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    type := PayloadType.ofUInt32 ((Wire.fieldUInt32? fields 1).getD 0)
    body := (Wire.fieldBytes? fields 2).getD ByteArray.empty
  }

/-- BoolValue { bool value = 1; } used by expect_compressed. -/
structure BoolValue where
  value : Bool := false
  deriving Inhabited

def BoolValue.encode (b : BoolValue) : ByteArray :=
  if b.value then Wire.encodeBool ByteArray.empty 1 true else ByteArray.empty

def BoolValue.decode (b : ByteArray) : Except String BoolValue := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return { value := (Wire.fieldUInt32? fields 1).getD 0 != 0 }

/-- Interop SimpleRequest (subset of grpc.testing.SimpleRequest).
    Field numbers match official messages.proto. -/
structure SimpleRequest where
  responseSize : UInt32 := 0
  fillUsername : Bool := false
  fillOauthScope : Bool := false
  responseCompressed : Option Bool := none
  responseStatus : Option EchoStatus := none
  expectCompressed : Option Bool := none
  payloadBody : ByteArray := ByteArray.empty
  /-- Opaque TestOrcaReport / load-report bytes (field 11). -/
  orcaPerQueryReport : ByteArray := ByteArray.empty
  deriving Inhabited

def SimpleRequest.encode (r : SimpleRequest) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    -- response_size=2, payload=3, fill_username=4, fill_oauth_scope=5,
    -- response_compressed=6, response_status=7, expect_compressed=8,
    -- orca_per_query_report=11
    if r.responseSize != 0 then
      acc := Wire.encodeUInt32 acc 2 r.responseSize
    if !r.payloadBody.isEmpty then
      acc := Wire.encodeBytes acc 3 (Payload.encode { body := r.payloadBody })
    if r.fillUsername then
      acc := Wire.encodeBool acc 4 true
    if r.fillOauthScope then
      acc := Wire.encodeBool acc 5 true
    if let some rc := r.responseCompressed then
      acc := Wire.encodeMessage acc 6 (BoolValue.encode { value := rc })
    if let some st := r.responseStatus then
      acc := Wire.encodeBytes acc 7 (EchoStatus.encode st)
    if let some ec := r.expectCompressed then
      acc := Wire.encodeMessage acc 8 (BoolValue.encode { value := ec })
    if !r.orcaPerQueryReport.isEmpty then
      acc := Wire.encodeBytes acc 11 r.orcaPerQueryReport
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
  let responseCompressed ←
    match Wire.fieldBytes? fields 6 with
    | none => pure none
    | some bb => some <$> (BoolValue.decode bb |>.map (·.value))
  let expectCompressed ←
    match Wire.fieldBytes? fields 8 with
    | none => pure none
    | some bb => some <$> (BoolValue.decode bb |>.map (·.value))
  return {
    responseSize := (Wire.fieldUInt32? fields 2).getD 0
    fillUsername := (Wire.fieldUInt32? fields 4).getD 0 != 0
    fillOauthScope := (Wire.fieldUInt32? fields 5).getD 0 != 0
    responseCompressed
    responseStatus
    payloadBody := payload
    expectCompressed
    orcaPerQueryReport := (Wire.fieldBytes? fields 11).getD ByteArray.empty
  }

structure SimpleResponse where
  username : String := ""
  oauthScope : String := ""
  payloadBody : ByteArray := ByteArray.empty
  deriving Inhabited

def SimpleResponse.encode (r : SimpleResponse) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.payloadBody.isEmpty then
      acc := Wire.encodeBytes acc 1 (Payload.encode { body := r.payloadBody })
    if !r.username.isEmpty then
      acc := Wire.encodeString acc 2 r.username
    if !r.oauthScope.isEmpty then
      acc := Wire.encodeString acc 3 r.oauthScope
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
    oauthScope := (Wire.fieldString? fields 3).getD ""
    payloadBody := payload
  }

/-- Streaming output call request (subset). -/
structure StreamingOutputCallRequest where
  responseParameters : Array UInt32 := #[]  -- sizes
  responseStatus : Option EchoStatus := none
  /-- When set, server should compress (true) or not (false) response payloads. -/
  responseCompressed : Option Bool := none
  deriving Inhabited

/-- Nested ResponseParameters; sizes are also exposed as a flat array for callers. -/
structure ResponseParameters where
  size : UInt32 := 0
  intervalUs : UInt32 := 0
  deriving Inhabited

def ResponseParameters.encode (p : ResponseParameters) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if p.size != 0 then acc := Wire.encodeUInt32 acc 1 p.size
    if p.intervalUs != 0 then acc := Wire.encodeUInt32 acc 2 p.intervalUs
    return acc

def ResponseParameters.decode (b : ByteArray) : Except String ResponseParameters := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    size := (Wire.fieldUInt32? fields 1).getD 0
    intervalUs := (Wire.fieldUInt32? fields 2).getD 0
  }

def StreamingOutputCallRequest.encode (r : StreamingOutputCallRequest) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    for sz in r.responseParameters do
      -- ResponseParameters { size = 1; } nested in field 2 (repeated)
      acc := Wire.encodeMessage acc 2 (ResponseParameters.encode { size := sz })
    if let some rc := r.responseCompressed then
      acc := Wire.encodeMessage acc 6 (BoolValue.encode { value := rc })
    if let some st := r.responseStatus then
      acc := Wire.encodeMessage acc 7 (EchoStatus.encode st)
    return acc

def StreamingOutputCallRequest.decode (b : ByteArray) : Except String StreamingOutputCallRequest := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let mut sizes : Array UInt32 := #[]
  for nested in Wire.fieldBytesMany fields 2 do
    let p ← ResponseParameters.decode nested
    sizes := sizes.push p.size
  let responseStatus ←
    match Wire.fieldBytes? fields 7 with
    | none => pure none
    | some sb => some <$> EchoStatus.decode sb
  let responseCompressed ←
    match Wire.fieldBytes? fields 6 with
    | none => pure none
    | some bb => some <$> (BoolValue.decode bb |>.map (·.value))
  return { responseParameters := sizes, responseStatus, responseCompressed }

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
  expectCompressed : Option Bool := none
  deriving Inhabited

def StreamingInputCallRequest.encode (r : StreamingInputCallRequest) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.payloadBody.isEmpty then
      acc := Wire.encodeBytes acc 1 (Payload.encode { body := r.payloadBody })
    if let some ec := r.expectCompressed then
      acc := Wire.encodeMessage acc 2 (BoolValue.encode { value := ec })
    return acc

def StreamingInputCallRequest.decode (b : ByteArray) : Except String StreamingInputCallRequest := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let payloadBytes := (Wire.fieldBytes? fields 1).getD ByteArray.empty
  let payload ←
    if payloadBytes.isEmpty then pure ByteArray.empty
    else do
      let p ← Payload.decode payloadBytes
      pure p.body
  let expectCompressed ←
    match Wire.fieldBytes? fields 2 with
    | none => pure none
    | some bb => some <$> (BoolValue.decode bb |>.map (·.value))
  return { payloadBody := payload, expectCompressed }

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
