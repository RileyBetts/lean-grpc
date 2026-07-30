/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice
import Bytes.BE
import Bytes.Pool
import Hpack
import Grpc.Metadata

namespace Grpc.Orca

/-- Trailing metadata key used for per-RPC ORCA load reports (base64 on wire). -/
def trailerKey : String := "endpoint-load-metrics-bin"

/-- Subset of `xds.data.orca.v3.OrcaLoadReport` / TestOrcaReport (fixed-point millis). -/
structure Report where
  cpuUtilizationMillis : UInt32 := 0
  memoryUtilizationMillis : UInt32 := 0
  deriving Inhabited, BEq

/-- Encode report as a tiny custom message (cpu=1, mem=2 as uint32 millis).
    Sufficient for Lean↔Lean ORCA smoke; full IEEE double ORCA is Phase-10+. -/
def Report.encode (r : Report) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if r.cpuUtilizationMillis != 0 then
      acc := Proto.Wire.encodeUInt32 acc 1 r.cpuUtilizationMillis
    if r.memoryUtilizationMillis != 0 then
      acc := Proto.Wire.encodeUInt32 acc 2 r.memoryUtilizationMillis
    return acc

def Report.decode (b : ByteArray) : Except String Report := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    cpuUtilizationMillis := (Proto.Wire.fieldUInt32? fields 1).getD 0
    memoryUtilizationMillis := (Proto.Wire.fieldUInt32? fields 2).getD 0
  }

def trailerField (r : Report) : Hpack.HeaderField :=
  ⟨Metadata.ascii trailerKey, Metadata.ascii (Metadata.base64Encode (Report.encode r))⟩

def reportFromTrailer? (trailers : Array Hpack.HeaderField) : Option Report :=
  Id.run do
    for h in trailers do
      let n := String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat))
      if n == trailerKey then
        let v := String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat))
        match Metadata.base64Decode v with
        | .error _ => pure ()
        | .ok bytes =>
          match Report.decode bytes with
          | .ok r => return some r
          | .error _ => pure ()
    return none

end Grpc.Orca
