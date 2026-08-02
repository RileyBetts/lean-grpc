/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- Demo RouteGuide server using typed streaming registration helpers. -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50052").toNat?.getD 50052 |>.toUInt16
  let mut s := Grpc.Server.empty
  s := Grpc.Server.registerTyped s "routeguide.RouteGuide" "GetFeature"
    Proto.Point.decode Proto.Feature.encode fun _ => do
      pure ({ name := "Lean Peak", location := { latitude := 1, longitude := 2 } }, Grpc.Status.ok)
  s := Grpc.Server.registerServerStreamTyped s "routeguide.RouteGuide" "ListFeatures"
    Proto.Rectangle.decode Proto.Feature.encode fun _ => do
      let feats : Array Proto.Feature := #[{ name := "Alpha" }, { name := "Beta" }, { name := "Gamma" }]
      pure (feats, Grpc.Status.ok)
  s := Grpc.Server.registerClientStreamTyped s "routeguide.RouteGuide" "RecordRoute"
    Proto.Point.decode Proto.RouteSummary.encode fun reqs => do
      pure ({ pointCount := reqs.size.toUInt32 }, Grpc.Status.ok)
  s := Grpc.Server.registerBidiTyped s "routeguide.RouteGuide" "RouteChat"
    Proto.RouteNote.decode Proto.RouteNote.encode fun reqs => do
      pure (reqs, Grpc.Status.ok)
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
