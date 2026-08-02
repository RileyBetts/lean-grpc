/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice

/-!
# Framing matrix wire messages

Clinical peer-framing probes (not a story demo). Field numbers match
`Tests/FramingMatrix/go/wire.go`.
-/

namespace Tests.FramingMatrix.Protocol

def serviceName : String := "framing.matrix.Probe"

structure Blob where
  text : String := ""
  deriving Inhabited

def Blob.encode (b : Blob) : ByteArray :=
  Proto.Wire.encodeString ByteArray.empty 1 b.text

def Blob.decode (b : ByteArray) : Except String Blob := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure { text := (Proto.Wire.fieldString? fields 1).getD "" }

structure Tally where
  count : UInt32 := 0
  xorFold : UInt32 := 0
  deriving Inhabited

def Tally.encode (t : Tally) : ByteArray :=
  Id.run do
    let mut acc := Proto.Wire.encodeUInt32 ByteArray.empty 1 t.count
    acc := Proto.Wire.encodeUInt32 acc 2 t.xorFold
    return acc

def Tally.decode (b : ByteArray) : Except String Tally := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  pure {
    count := (Proto.Wire.fieldUInt32? fields 1).getD 0
    xorFold := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

def foldXor (bs : ByteArray) : UInt32 :=
  Id.run do
    let mut x : UInt32 := 0
    for i in [:bs.size] do
      x := x ^^^ (bs.get! i).toUInt32
    return x

def foldXorString (s : String) : UInt32 :=
  foldXor s.toUTF8

end Tests.FramingMatrix.Protocol
