/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Examples.SignalWeave.Protocol

open Examples.SignalWeave.Protocol

/-- Lean spectrum-exchange server for the Go SignalWeave client. -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50301").toNat?.getD 50301 |>.toUInt16
  let health ← IO.mkRef Grpc.Health.ServingStatus.serving
  let mut s := Grpc.Server.empty

  s := Grpc.Server.register s serviceName "Tune" fun reqBytes => do
    let req ← IO.ofExcept (TuneRequest.decode reqBytes)
    if req.station.isEmpty then
      return (ByteArray.empty, Grpc.Status.invalidArgument "station required")
    if req.khz < 100 then
      return (ByteArray.empty, Grpc.Status.outOfRange "khz too low")
    let ch := (req.khz / 25) % 64
    let reply := TuneReply.encode { grant := s!"OK:{req.station}", channel := ch }
    return (reply, Grpc.Status.ok)

  s := Grpc.Server.registerServerStream s serviceName "Spectrum" fun reqBytes => do
    let req ← IO.ofExcept (TuneRequest.decode reqBytes)
    let base := if req.khz == 0 then 100 else (req.khz / 1000)
    let bands : Array Band := #[
      { mhz := base, snrMilli := 12000 },
      { mhz := base + 1, snrMilli := 8500 },
      { mhz := base + 2, snrMilli := 4100 },
      { mhz := base + 3, snrMilli := 22000 }
    ]
    return (bands.map Band.encode, Grpc.Status.ok)

  s := Grpc.Server.registerClientStream s serviceName "Uplink" fun msgs => do
    if msgs.size < 2 then
      return (ByteArray.empty, Grpc.Status.invalidArgument "need ≥2 bursts")
    let mut x : UInt32 := 0
    for m in msgs do
      let b ← IO.ofExcept (Burst.decode m)
      x := x ^^^ foldXor b.payload
    return (UplinkAck.encode { xorFold := x, count := msgs.size.toUInt32 }, Grpc.Status.ok)

  s := Grpc.Server.registerBidi s serviceName "Handshake" fun msgs => do
    let mut out : Array ByteArray := #[]
    let mut locked := false
    for m in msgs do
      let w ← IO.ofExcept (Wave.decode m)
      if locked then
        out := out.push (Wave.encode { kind := "LOCK", note := "already" })
      else if w.kind == "SYN" then
        out := out.push (Wave.encode { kind := "ACK", note := w.note })
      else if w.kind == "ACK" && w.note == "weave" then
        locked := true
        out := out.push (Wave.encode { kind := "LOCK", note := "linked" })
      else
        out := out.push (Wave.encode { kind := "NAK", note := "unexpected" })
    let st : Grpc.Status :=
      if locked then Grpc.Status.ok
      else { code := .failedPrecondition, message := "not locked" }
    return (out, st)

  s := Grpc.Server.register s serviceName "Blackout" fun _ => do
    return (ByteArray.empty, Grpc.Status.internal "ionospheric blackout")

  s := Grpc.Server.register s serviceName "SlowTune" fun reqBytes => do
    IO.sleep 1500
    let req ← IO.ofExcept (TuneRequest.decode reqBytes)
    return (TuneReply.encode { grant := s!"late:{req.station}", channel := 1 }, Grpc.Status.ok)

  s := Grpc.Health.registerWithWatch s health
  IO.println s!"SignalWeave Lean server on 127.0.0.1:{port.toNat}"
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
