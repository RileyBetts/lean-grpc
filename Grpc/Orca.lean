/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice
import Bytes.BE
import Bytes.Pool
import Hpack
import Grpc.Metadata
import Grpc.Server
import Grpc.Status
import Grpc.Stream
import Grpc.Channel

namespace Grpc.Orca

/-- Trailing metadata key used for per-RPC ORCA load reports (base64 on wire). -/
def trailerKey : String := "endpoint-load-metrics-bin"

/-- Subset of `xds.data.orca.v3.OrcaLoadReport`: real IEEE-754 `double` utilization fields
    (matching the wire proto) rather than a fixed-point placeholder. -/
structure Report where
  cpuUtilization : Float := 0.0
  memUtilization : Float := 0.0
  applicationUtilization : Float := 0.0
  deriving Inhabited, BEq

/-- `OrcaLoadReport { cpu_utilization = 1; mem_utilization = 2; application_utilization = 4 }`. -/
def Report.encode (r : Report) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if r.cpuUtilization != 0.0 then acc := Proto.Wire.encodeDouble acc 1 r.cpuUtilization
    if r.memUtilization != 0.0 then acc := Proto.Wire.encodeDouble acc 2 r.memUtilization
    if r.applicationUtilization != 0.0 then
      acc := Proto.Wire.encodeDouble acc 4 r.applicationUtilization
    return acc

def Report.decode (b : ByteArray) : Except String Report := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    cpuUtilization := (Proto.Wire.fieldDouble? fields 1).getD 0.0
    memUtilization := (Proto.Wire.fieldDouble? fields 2).getD 0.0
    applicationUtilization := (Proto.Wire.fieldDouble? fields 4).getD 0.0
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

/-! # Out-of-band ORCA reporting (`xds.service.orca.v3.OpenRcaService/StreamCoreMetrics`).

    Real OOB reporting is server-streaming: the client sends one `OrcaLoadReportRequest`
    (a report interval) and the server keeps pushing fresh `OrcaLoadReport`s on that cadence.
    This minimal implementation answers with a single current snapshot per call — the RPC
    shape (service name, method, message framing) matches the real proto, so it composes with
    a real ORCA-aware client/LB; only the "keep streaming forever" part is out of scope. -/

def oobService : String := "xds.service.orca.v3.OpenRcaService"
def oobMethod : String := "StreamCoreMetrics"

/-- Register the out-of-band metrics stream, backed by a live `Report` ref that request
    handlers (or a background updater) can keep current via `IO.Ref.set`. -/
def registerOob (s : Server) (reportRef : IO.Ref Report) : Server :=
  Server.registerServerStream s oobService oobMethod fun _req => do
    let r ← reportRef.get
    return (#[Report.encode r], Status.ok)

/-- Client-side: open the OOB stream and read one report. -/
def fetchOob (ch : Channel) : IO Report := do
  let stream ← Channel.openStream ch oobService oobMethod
  Stream.StreamWriter.halfClose stream.writer
  match ← Stream.StreamReader.recv? stream.reader with
  | none => throw (IO.userError "orca oob: empty response")
  | some msg => IO.ofExcept (Report.decode msg)

end Grpc.Orca
