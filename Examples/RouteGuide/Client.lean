/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto

/-- RouteGuide client using `Channel` streaming helpers (not raw `H2.Client.unary`). -/
def main (args : List String) : IO Unit := do
  let host := args[0]?.getD "127.0.0.1"
  let port := (args[1]?.getD "50052").toNat?.getD 50052 |>.toUInt16
  let ch ← Grpc.Channel.connectH2c host port

  -- GetFeature (unary)
  let point := Proto.Point.encode { latitude := 1, longitude := 2 }
  let r1 ← Grpc.Channel.unary ch "routeguide.RouteGuide" "GetFeature" point
  if r1.status.code != .ok then
    throw (IO.userError s!"GetFeature failed: {r1.status.message}")
  let feat ← IO.ofExcept (Proto.Feature.decode r1.message)
  IO.println s!"GetFeature name={feat.name}"

  -- ListFeatures (server streaming)
  let (feats, st2) ← Grpc.Channel.serverStream ch "routeguide.RouteGuide" "ListFeatures" ByteArray.empty
  if st2.code != .ok then
    throw (IO.userError s!"ListFeatures failed: {st2.message}")
  IO.println s!"ListFeatures count={feats.size}"

  -- RecordRoute (client streaming)
  let points := #[point, point, point]
  let r3 ← Grpc.Channel.clientStream ch "routeguide.RouteGuide" "RecordRoute" points
  if r3.status.code != .ok then
    throw (IO.userError s!"RecordRoute failed: {r3.status.message}")
  let summary ← IO.ofExcept (Proto.RouteSummary.decode r3.message)
  IO.println s!"RecordRoute pointCount={summary.pointCount}"

  -- RouteChat (bidi echo)
  let note := Proto.RouteNote.encode { message := "hello", location := { latitude := 1, longitude := 2 } }
  let (notes, st4) ← Grpc.Channel.bidiStream ch "routeguide.RouteGuide" "RouteChat" #[note]
  if st4.code != .ok then
    throw (IO.userError s!"RouteChat failed: {st4.message}")
  IO.println s!"RouteChat echo count={notes.size}"
  IO.println "routeGuide client OK"
