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
import Grpc.Tls

namespace Grpc.XdsAds

/-- Cleartext ADS is allowed only with `LEAN_GRPC_XDS_INSECURE=1` (tests/FakeAds). -/
private def connectAds (server : Resolver.Address) : IO H2.ClientConn := do
  match ← IO.getEnv "LEAN_GRPC_XDS_INSECURE" with
  | some "1" =>
    IO.eprintln "WARN: LEAN_GRPC_XDS_INSECURE=1 → ADS over cleartext h2c"
    H2.Client.connectH2c server.host server.port
  | _ =>
    -- Default: TLS with system trust store + hostname verify.
    Grpc.Tls.connectH2 server.host server.port {}

private def adsHeaders (host : String) (useHttps : Bool) : Array Hpack.HeaderField :=
  #[
    Metadata.methodPost,
    if useHttps then Metadata.schemeHttps else Metadata.schemeHttp,
    ⟨Metadata.ascii ":authority", Metadata.ascii host⟩,
    Metadata.path "envoy.service.discovery.v3.AggregatedDiscoveryService"
      "StreamAggregatedResources",
    Metadata.contentTypeGrpc,
    Metadata.teTrailers
  ]

private def adsInsecure? : IO Bool := do
  match ← IO.getEnv "LEAN_GRPC_XDS_INSECURE" with
  | some "1" => pure true
  | _ => pure false

/-- ADS client: DiscoveryRequest → DiscoveryResponse over gRPC bidi
    (`AggregatedDiscoveryService/StreamAggregatedResources`).
    Speaks real envoy.service.discovery.v3 protobuf (EDS CLA resources). -/
def fetchViaAds (server : Resolver.Address) (cluster : String) : IO (Array Resolver.Address) := do
  let conn ← connectAds server
  let insecure ← adsInsecure?
  let stream ← Stream.openCall conn (adsHeaders server.host (!insecure))
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

/-! # ADS session — single bidi stream carrying LDS/RDS/CDS/EDS/SDS exchanges.

    Real ADS multiplexes every resource type over one `StreamAggregatedResources` stream;
    this client does the same (one `H2` bidi stream per session, one discovery
    request/response pair per resource type/name), with version/nonce ACK/NACK plumbing
    per the xDS protocol (see `Grpc.Xds.Discovery.Request.ack` / `.nack`). -/
structure Session where
  stream : Stream.ClientStream
  host : String

/-- Open a new ADS session against `server`. -/
def Session.open (server : Resolver.Address) : IO Session := do
  let conn ← connectAds server
  let insecure ← adsInsecure?
  let stream ← Stream.openCall conn (adsHeaders server.host (!insecure))
  return { stream, host := server.host }

/-- Send one `DiscoveryRequest` and await its `DiscoveryResponse` on the session stream. -/
def Session.exchange (s : Session) (req : Xds.Discovery.Request) : IO Xds.Discovery.Response := do
  Stream.StreamWriter.send s.stream.writer (Xds.Discovery.Request.encode req)
  match ← Stream.StreamReader.recv? s.stream.reader with
  | none => throw (IO.userError s!"ads: empty response for {req.typeUrl}")
  | some msg => IO.ofExcept (Xds.Discovery.Response.decode msg)

/-- Fetch one resource type, ACK on success. Sends a NACK and returns `.error` if any
    returned resource's inner `Any.type_url` does not match `expectedTypeUrl` (the
    canonical trigger for a real xDS client to reject a response).

    ACK/NACK follow-ups are fire-and-forget (a real control plane does not necessarily push
    a fresh response just because it was acknowledged/rejected), so they are sent directly on
    the writer rather than through `exchange` — waiting for a reply there could stall forever. -/
def Session.fetchTyped (s : Session) (expectedTypeUrl : String) (resourceNames : Array String)
    (version : String := "") : IO (Except String Xds.Discovery.Response) := do
  let resp ← s.exchange { resourceNames, typeUrl := expectedTypeUrl, versionInfo := version }
  -- Require non-empty matching type_url on every resource (LGSEC-2026-22).
  let mismatched :=
    resp.resources.any (fun a => a.typeUrl.isEmpty || a.typeUrl != expectedTypeUrl)
  if mismatched then
    let nack := Xds.Discovery.Request.nack expectedTypeUrl version resp.nonce
      s!"resource type_url mismatch: expected {expectedTypeUrl}" resourceNames
    Stream.StreamWriter.send s.stream.writer (Xds.Discovery.Request.encode nack)
    return .error s!"ads NACK: type_url mismatch fetching {expectedTypeUrl} ({resourceNames})"
  let ack := Xds.Discovery.Request.ack expectedTypeUrl resp.versionInfo resp.nonce resourceNames
  Stream.StreamWriter.send s.stream.writer (Xds.Discovery.Request.encode ack)
  return .ok resp

def Session.close (s : Session) : IO Unit :=
  Stream.StreamWriter.halfClose s.stream.writer

/-- End-to-end xDS client resolution: LDS(listener) → RDS(route config) → CDS(cluster) →
    EDS(endpoints), all over one ADS session. Mirrors how a real gRPC xDS-enabled client
    resolves an `xds:///listenerName` target via ADS. -/
def resolveChain (server : Resolver.Address) (listenerName : String) : IO (Array Resolver.Address) := do
  let s ← Session.open server
  let ldsResp ←
    match ← s.fetchTyped Xds.ldsTypeUrl #[listenerName] with
    | .ok r => pure r
    | .error e => throw (IO.userError e)
  if ldsResp.resources.isEmpty then throw (IO.userError "ads: no LDS resources")
  let listener ← IO.ofExcept (Xds.Discovery.Listener.decode ldsResp.resources[0]!.value)
  let routeConfigName ←
    match listener.routeConfigName with
    | some n => pure n
    | none => throw (IO.userError "ads: listener missing route_config_name")
  let rdsResp ←
    match ← s.fetchTyped Xds.rdsTypeUrl #[routeConfigName] with
    | .ok r => pure r
    | .error e => throw (IO.userError e)
  if rdsResp.resources.isEmpty then throw (IO.userError "ads: no RDS resources")
  let routeConfig ← IO.ofExcept (Xds.Discovery.RouteConfiguration.decode rdsResp.resources[0]!.value)
  let clusterName ←
    match Xds.Discovery.RouteConfiguration.firstClusterName? routeConfig with
    | some c => pure c
    | none => throw (IO.userError "ads: route config missing cluster")
  let cdsResp ←
    match ← s.fetchTyped Xds.cdsTypeUrl #[clusterName] with
    | .ok r => pure r
    | .error e => throw (IO.userError e)
  if cdsResp.resources.isEmpty then throw (IO.userError "ads: no CDS resources")
  let cluster ← IO.ofExcept (Xds.Discovery.Cluster.decode cdsResp.resources[0]!.value)
  let edsName := if cluster.edsServiceName.isEmpty then cluster.name else cluster.edsServiceName
  let edsResp ←
    match ← s.fetchTyped Xds.edsTypeUrl #[edsName] with
    | .ok r => pure r
    | .error e => throw (IO.userError e)
  s.close
  let addrs := Xds.Discovery.endpointsFromResponse edsResp
  if addrs.isEmpty then throw (IO.userError "ads: no EDS endpoints")
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
