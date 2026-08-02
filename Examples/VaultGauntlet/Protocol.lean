/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice

/-!
# VaultGauntlet wire messages

A short, multi-act heist protocol used to stress lean-grpc (unary, streaming,
compression, metadata, deadlines, RST/cancel, status details, content-type 415).
-/

namespace Examples.VaultGauntlet.Protocol

def serviceName : String := "vault.gauntlet.Vault"
def vaultPassword : String := "LEAN-GRPC-OPEN"

structure EnlistRequest where
  name : String := ""
  deriving Inhabited

def EnlistRequest.encode (r : EnlistRequest) : ByteArray :=
  Proto.Wire.encodeString ByteArray.empty 1 r.name

def EnlistRequest.decode (b : ByteArray) : Except String EnlistRequest := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure { name := (Proto.Wire.fieldString? fields 1).getD "" }

structure EnlistReply where
  token : ByteArray := ByteArray.empty
  nonce : UInt32 := 0
  deriving Inhabited

def EnlistReply.encode (r : EnlistReply) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.token.isEmpty then acc := Proto.Wire.encodeBytes acc 1 r.token
    if r.nonce != 0 then acc := Proto.Wire.encodeUInt32 acc 2 r.nonce
    return acc

def EnlistReply.decode (b : ByteArray) : Except String EnlistReply := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    token := (Proto.Wire.fieldBytes? fields 1).getD ByteArray.empty
    nonce := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

structure Clue where
  index : UInt32 := 0
  text : String := ""
  deriving Inhabited

def Clue.encode (c : Clue) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeUInt32 ByteArray.empty 1 c.index
    acc := Proto.Wire.encodeString acc 2 c.text
    return acc

def Clue.decode (b : ByteArray) : Except String Clue := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    index := (Proto.Wire.fieldUInt32? fields 1).getD 0
    text := (Proto.Wire.fieldString? fields 2).getD ""
  }

structure Shard where
  material : ByteArray := ByteArray.empty
  deriving Inhabited

def Shard.encode (s : Shard) : ByteArray :=
  Proto.Wire.encodeBytes ByteArray.empty 1 s.material

def Shard.decode (b : ByteArray) : Except String Shard := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure { material := (Proto.Wire.fieldBytes? fields 1).getD ByteArray.empty }

structure DepositReply where
  xorFold : UInt32 := 0
  count : UInt32 := 0
  deriving Inhabited

def DepositReply.encode (r : DepositReply) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeUInt32 ByteArray.empty 1 r.xorFold
    acc := Proto.Wire.encodeUInt32 acc 2 r.count
    return acc

def DepositReply.decode (b : ByteArray) : Except String DepositReply := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    xorFold := (Proto.Wire.fieldUInt32? fields 1).getD 0
    count := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

structure PickAttempt where
  guess : String := ""
  deriving Inhabited

def PickAttempt.encode (a : PickAttempt) : ByteArray :=
  Proto.Wire.encodeString ByteArray.empty 1 a.guess

def PickAttempt.decode (b : ByteArray) : Except String PickAttempt := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure { guess := (Proto.Wire.fieldString? fields 1).getD "" }

structure PickHint where
  opened : Bool := false
  hint : String := ""
  deriving Inhabited

def PickHint.encode (h : PickHint) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeBool ByteArray.empty 1 h.opened
    acc := Proto.Wire.encodeString acc 2 h.hint
    return acc

def PickHint.decode (b : ByteArray) : Except String PickHint := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    opened := (Proto.Wire.fieldUInt32? fields 1).getD 0 != 0
    hint := (Proto.Wire.fieldString? fields 2).getD ""
  }

/-- Deterministic session token from name + nonce. -/
def mintToken (name : String) (nonce : UInt32) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for c in name.toList do
      out := out.push (c.toNat.toUInt8 ^^^ (nonce &&& 255).toUInt8)
    out := out.push (nonce >>> 8).toUInt8
    out := out.push nonce.toUInt8
    return out

def foldXor (bs : ByteArray) : UInt32 :=
  Id.run do
    let mut x : UInt32 := 0
    for i in [:bs.size] do
      x := x ^^^ (bs.get! i).toUInt32
    return x

end Examples.VaultGauntlet.Protocol
