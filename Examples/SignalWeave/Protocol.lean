/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice

/-!
# SignalWeave wire messages

Go client ↔ Lean server stress protocol (spectrum exchange).
Field numbers match `Examples/SignalWeave/go/wire.go`.
-/

namespace Examples.SignalWeave.Protocol

def serviceName : String := "signal.weave.Exchange"

structure TuneRequest where
  station : String := ""
  khz : UInt32 := 0
  deriving Inhabited

def TuneRequest.encode (r : TuneRequest) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeString ByteArray.empty 1 r.station
    if r.khz != 0 then acc := Proto.Wire.encodeUInt32 acc 2 r.khz
    return acc

def TuneRequest.decode (b : ByteArray) : Except String TuneRequest := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    station := (Proto.Wire.fieldString? fields 1).getD ""
    khz := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

structure TuneReply where
  grant : String := ""
  channel : UInt32 := 0
  deriving Inhabited

def TuneReply.encode (r : TuneReply) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeString ByteArray.empty 1 r.grant
    if r.channel != 0 then acc := Proto.Wire.encodeUInt32 acc 2 r.channel
    return acc

def TuneReply.decode (b : ByteArray) : Except String TuneReply := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    grant := (Proto.Wire.fieldString? fields 1).getD ""
    channel := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

structure Band where
  mhz : UInt32 := 0
  snrMilli : UInt32 := 0  -- SNR × 1000 as integer (avoid float edge cases on wire)
  deriving Inhabited

def Band.encode (b : Band) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeUInt32 ByteArray.empty 1 b.mhz
    acc := Proto.Wire.encodeUInt32 acc 2 b.snrMilli
    return acc

def Band.decode (b : ByteArray) : Except String Band := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    mhz := (Proto.Wire.fieldUInt32? fields 1).getD 0
    snrMilli := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

structure Burst where
  payload : ByteArray := ByteArray.empty
  deriving Inhabited

def Burst.encode (b : Burst) : ByteArray :=
  Proto.Wire.encodeBytes ByteArray.empty 1 b.payload

def Burst.decode (b : ByteArray) : Except String Burst := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure { payload := (Proto.Wire.fieldBytes? fields 1).getD ByteArray.empty }

structure UplinkAck where
  xorFold : UInt32 := 0
  count : UInt32 := 0
  deriving Inhabited

def UplinkAck.encode (a : UplinkAck) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeUInt32 ByteArray.empty 1 a.xorFold
    acc := Proto.Wire.encodeUInt32 acc 2 a.count
    return acc

def UplinkAck.decode (b : ByteArray) : Except String UplinkAck := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    xorFold := (Proto.Wire.fieldUInt32? fields 1).getD 0
    count := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

structure Wave where
  kind : String := ""
  note : String := ""
  deriving Inhabited

def Wave.encode (w : Wave) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeString ByteArray.empty 1 w.kind
    acc := Proto.Wire.encodeString acc 2 w.note
    return acc

def Wave.decode (b : ByteArray) : Except String Wave := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    kind := (Proto.Wire.fieldString? fields 1).getD ""
    note := (Proto.Wire.fieldString? fields 2).getD ""
  }

def foldXor (bs : ByteArray) : UInt32 :=
  Id.run do
    let mut x : UInt32 := 0
    for i in [:bs.size] do
      x := x ^^^ (bs.get! i).toUInt32
    return x

end Examples.SignalWeave.Protocol
