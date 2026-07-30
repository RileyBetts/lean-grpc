/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Demo RouteGuide server using public streaming registration APIs. -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50052").toNat?.getD 50052 |>.toUInt16
  let mut s := Grpc.Server.empty
  s := Grpc.Server.register s "routeguide.RouteGuide" "GetFeature" fun req => do
    let _ ← IO.ofExcept (Proto.Point.decode req)
    let reply := Proto.Feature.encode { name := "Lean Peak", location := { latitude := 1, longitude := 2 } }
    return (reply, Grpc.Status.ok)
  s := Grpc.Server.registerServerStream s "routeguide.RouteGuide" "ListFeatures" fun _ => do
    let mut msgs : Array ByteArray := #[]
    for name in ["Alpha", "Beta", "Gamma"] do
      msgs := msgs.push (Proto.Feature.encode { name })
    return (msgs, Grpc.Status.ok)
  s := Grpc.Server.registerClientStream s "routeguide.RouteGuide" "RecordRoute" fun reqs => do
    let summary := Proto.RouteSummary.encode { pointCount := reqs.size.toUInt32 }
    return (summary, Grpc.Status.ok)
  s := Grpc.Server.registerBidi s "routeguide.RouteGuide" "RouteChat" fun reqs => do
    return (reqs, Grpc.Status.ok)  -- echo
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
