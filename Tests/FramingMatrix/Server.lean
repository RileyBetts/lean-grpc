/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Tests.FramingMatrix.Protocol

open Tests.FramingMatrix.Protocol

/-- Lean peer for the framing matrix (Lean + Go clients). -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50310").toNat?.getD 50310 |>.toUInt16
  let mut s := Grpc.Server.empty

  s := Grpc.Server.register s serviceName "Echo" fun reqBytes => do
    let req ← IO.ofExcept (Blob.decode reqBytes)
    return (Blob.encode { text := s!"echo:{req.text}" }, Grpc.Status.ok)

  s := Grpc.Server.registerServerStream s serviceName "FanOut" fun reqBytes => do
    let req ← IO.ofExcept (Blob.decode reqBytes)
    let msgs := #[
      Blob.encode { text := s!"{req.text}:1" },
      Blob.encode { text := s!"{req.text}:2" },
      Blob.encode { text := s!"{req.text}:3" }
    ]
    return (msgs, Grpc.Status.ok)

  s := Grpc.Server.registerClientStream s serviceName "Collect" fun msgs => do
    if msgs.isEmpty then
      return (ByteArray.empty, Grpc.Status.invalidArgument "need ≥1 blob")
    let mut x : UInt32 := 0
    for m in msgs do
      let b ← IO.ofExcept (Blob.decode m)
      x := x ^^^ foldXorString b.text
    return (Tally.encode { count := msgs.size.toUInt32, xorFold := x }, Grpc.Status.ok)

  -- Incremental bidi: one response per request; empty half-close must not wipe state.
  s := Grpc.Server.registerBidi s serviceName "Relay" fun msgs => do
    if msgs.isEmpty then
      -- Should not be reached after empty-half-close stack fix; defensive OK.
      return (#[], Grpc.Status.ok)
    let mut out : Array ByteArray := #[]
    for m in msgs do
      let b ← IO.ofExcept (Blob.decode m)
      out := out.push (Blob.encode { text := s!"R:{b.text}" })
    return (out, Grpc.Status.ok)

  s := Grpc.Server.register s serviceName "SlowEcho" fun reqBytes => do
    IO.sleep 500
    let req ← IO.ofExcept (Blob.decode reqBytes)
    return (Blob.encode { text := s!"late:{req.text}" }, Grpc.Status.ok)

  IO.println s!"FramingMatrix Lean server on 127.0.0.1:{port.toNat}"
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
