/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice

/-!
# MirrorForge wire messages

Lean↔Lean dual-forge stress protocol: round-robin, retry, interceptors,
health Watch, reflection, channelz, binary log, stats, ORCA OOB.
-/

namespace Examples.MirrorForge.Protocol

def serviceName : String := "forge.mirror.Mirror"
def accessToken : String := "molten-key-7"

structure StampRequest where
  token : String := ""
  billet : String := ""
  deriving Inhabited

def StampRequest.encode (r : StampRequest) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeString ByteArray.empty 1 r.token
    acc := Proto.Wire.encodeString acc 2 r.billet
    return acc

def StampRequest.decode (b : ByteArray) : Except String StampRequest := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    token := (Proto.Wire.fieldString? fields 1).getD ""
    billet := (Proto.Wire.fieldString? fields 2).getD ""
  }

structure StampReply where
  forgeId : String := ""
  mark : String := ""
  cpuLoad : Float := 0.0
  deriving Inhabited

def StampReply.encode (r : StampReply) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeString ByteArray.empty 1 r.forgeId
    acc := Proto.Wire.encodeString acc 2 r.mark
    if r.cpuLoad != 0.0 then acc := Proto.Wire.encodeDouble acc 3 r.cpuLoad
    return acc

def StampReply.decode (b : ByteArray) : Except String StampReply := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    forgeId := (Proto.Wire.fieldString? fields 1).getD ""
    mark := (Proto.Wire.fieldString? fields 2).getD ""
    cpuLoad := (Proto.Wire.fieldDouble? fields 3).getD 0.0
  }

end Examples.MirrorForge.Protocol
