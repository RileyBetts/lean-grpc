/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import H2

/-- Minimal ADS server: bidi StreamAggregatedResources → DiscoveryResponse + CLA.
    Usage: fakeAdsServer <listen-port> <endpoint-host:port> [<cluster-name>] -/
def main (args : List String) : IO Unit := do
  let port := (args[0]?.getD "18000").toNat?.getD 18000 |>.toUInt16
  let endpoint := args[1]?.getD "127.0.0.1:10000"
  let cluster := args[2]?.getD "test"
  let svc := "envoy.service.discovery.v3.AggregatedDiscoveryService"
  let method := "StreamAggregatedResources"
  let respBytes ← IO.ofExcept do
    let resp ← Grpc.Xds.Discovery.edsResponse cluster endpoint
    pure (Grpc.Xds.Discovery.Response.encode resp)
  let h : Grpc.Stream.BidiStreamHandler := fun reqs => do
    -- Optionally validate DiscoveryRequest type_url / resource_names.
    for req in reqs do
      match Grpc.Xds.Discovery.Request.decode req with
      | .ok r =>
        if !r.typeUrl.isEmpty && r.typeUrl != Grpc.Xds.edsTypeUrl &&
            r.typeUrl != Grpc.Xds.cdsTypeUrl then
          return (#[], Grpc.Status.invalidArgument s!"bad type_url {r.typeUrl}")
      | .error _ => pure ()
    return (#[respBytes], Grpc.Status.ok)
  let s := Grpc.Server.empty |>.registerBidi svc method h
  IO.println s!"FakeAds (protobuf EDS) on 127.0.0.1:{port} → {endpoint} (cluster={cluster})"
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
