/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2
import Hpack
import Grpc.Xds
import Grpc.Xds.Discovery
import Grpc.Metadata
import Grpc.Stream
import Grpc.Resolver

namespace Grpc.XdsAds

/-- ADS client: DiscoveryRequest → DiscoveryResponse over gRPC bidi
    (`AggregatedDiscoveryService/StreamAggregatedResources`).
    Speaks real envoy.service.discovery.v3 protobuf (EDS CLA resources). -/
def fetchViaAds (server : Resolver.Address) (cluster : String) : IO (Array Resolver.Address) := do
  let conn ← H2.Client.connectH2c server.host server.port
  let headers : Array Hpack.HeaderField :=
    #[
      Metadata.methodPost,
      Metadata.schemeHttp,
      ⟨Metadata.ascii ":authority", Metadata.ascii server.host⟩,
      Metadata.path "envoy.service.discovery.v3.AggregatedDiscoveryService"
        "StreamAggregatedResources",
      Metadata.contentTypeGrpc,
      Metadata.teTrailers
    ]
  let stream ← Stream.openCall conn headers
  let req : Xds.Discovery.Request := {
    resourceNames := #[cluster]
    typeUrl := Xds.edsTypeUrl
  }
  Stream.StreamWriter.send stream.writer (Xds.Discovery.Request.encode req)
  Stream.StreamWriter.halfClose stream.writer
  match ← Stream.StreamReader.recv? stream.reader with
  | none => throw (IO.userError "ads: empty response")
  | some msg =>
    let resp ← IO.ofExcept (Xds.Discovery.Response.decode msg)
    let addrs := Xds.Discovery.endpointsFromResponse resp
    if addrs.isEmpty then
      throw (IO.userError s!"ads: no endpoints (type_url={resp.typeUrl} resources={resp.resources.size})")
    return addrs

/-- Resolve `xds:///name`: prefer ADS when bootstrap has `xds_servers`, else static clusters. -/
def resolveFromEnv (target : String) : IO (Array Resolver.Address) := do
  match ← IO.getEnv "LEAN_GRPC_XDS_BOOTSTRAP" with
  | none => throw (IO.userError "LEAN_GRPC_XDS_BOOTSTRAP not set")
  | some path =>
    let boot ← Xds.loadBootstrapFile path
    let name ← IO.ofExcept (Xds.clusterName target)
    if boot.xdsServers.size > 0 then
      let srv := boot.xdsServers[0]!
      try
        return (← fetchViaAds srv name)
      catch e =>
        IO.eprintln s!"ads resolve failed ({e}); trying static clusters"
        IO.ofExcept (Xds.resolve boot target)
    else
      IO.ofExcept (Xds.resolve boot target)

end Grpc.XdsAds
