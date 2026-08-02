/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import H2

/-- Minimal ADS server: bidi StreamAggregatedResources serving the full
    LDS → RDS → CDS → EDS chain (plus an SDS stub) over one multiplexed stream.
    Each incoming `DiscoveryRequest` is answered independently by `type_url`/`resource_names`,
    so a single client session can walk the whole chain without reconnecting.

    A NACK path is exercised via the well-known resource name `nack-test`: requesting it under
    `Grpc.Xds.cdsTypeUrl` returns a resource whose inner `Any.type_url` is deliberately the EDS
    type — a real xDS client detects the mismatch and NACKs, which this server logs (and does
    not re-push, since the client already has nothing usable).

    Usage: fakeAdsServer <listen-port> <endpoint-host:port> [<cluster-name>] [<cert-path>] [<key-path>] -/
def main (args : List String) : IO Unit := do
  let port := (args[0]?.getD "18000").toNat?.getD 18000 |>.toUInt16
  let endpoint := args[1]?.getD "127.0.0.1:10000"
  let cluster := args[2]?.getD "test"
  let certPath? := args[3]?
  let keyPath? := args[4]?
  let routeConfigName := s!"{cluster}-route"
  let svc := "envoy.service.discovery.v3.AggregatedDiscoveryService"
  let method := "StreamAggregatedResources"

  -- Build the response for one decoded request, or `none` to emit nothing this round.
  let respond (req : Grpc.Xds.Discovery.Request) : IO (Option ByteArray) := do
    if let some ed := req.errorDetail then
      IO.eprintln s!"FakeAds: NACK received type_url={req.typeUrl} msg={ed.message}"
      return none
    if !req.responseNonce.isEmpty then
      -- ACK of a previous response (no error_detail): nothing new to push.
      return none
    let names := if req.resourceNames.isEmpty then #[cluster] else req.resourceNames
    if req.typeUrl == Grpc.Xds.ldsTypeUrl then
      let name := names[0]!
      return some (Grpc.Xds.Discovery.Response.encode
        (Grpc.Xds.Discovery.ldsResponse name routeConfigName))
    else if req.typeUrl == Grpc.Xds.rdsTypeUrl then
      let name := names[0]!
      return some (Grpc.Xds.Discovery.Response.encode
        (Grpc.Xds.Discovery.rdsResponse name cluster))
    else if req.typeUrl == Grpc.Xds.cdsTypeUrl then
      let name := names[0]!
      if name == "nack-test" then
        -- Deliberately mismatched inner type_url (looks like an EDS resource) to force a NACK.
        let bad ← IO.ofExcept (Grpc.Xds.Discovery.edsResponse name endpoint)
        return some (Grpc.Xds.Discovery.Response.encode { bad with typeUrl := Grpc.Xds.cdsTypeUrl })
      else
        return some (Grpc.Xds.Discovery.Response.encode
          (Grpc.Xds.Discovery.cdsResponse name name))
    else if req.typeUrl == Grpc.Xds.edsTypeUrl then
      let name := names[0]!
      let resp ← IO.ofExcept (Grpc.Xds.Discovery.edsResponse name endpoint)
      return some (Grpc.Xds.Discovery.Response.encode resp)
    else if req.typeUrl == Grpc.Xds.sdsTypeUrl then
      match certPath?, keyPath? with
      | some cert, some key =>
        let name := names[0]!
        return some (Grpc.Xds.Discovery.Response.encode
          (Grpc.Xds.Discovery.sdsResponse name cert key))
      | _, _ => return none
    else if req.typeUrl.isEmpty then
      -- Legacy smoke path: bare EDS-by-cluster-name request (no type_url set).
      let resp ← IO.ofExcept (Grpc.Xds.Discovery.edsResponse names[0]! endpoint)
      return some (Grpc.Xds.Discovery.Response.encode resp)
    else
      IO.eprintln s!"FakeAds: unknown type_url {req.typeUrl}"
      return none

  let h : Grpc.Stream.BidiStreamHandler := fun reqs => do
    let mut out : Array ByteArray := #[]
    for reqBytes in reqs do
      match Grpc.Xds.Discovery.Request.decode reqBytes with
      | .error e => IO.eprintln s!"FakeAds: bad request ({e})"
      | .ok req =>
        match ← respond req with
        | some bytes => out := out.push bytes
        | none => pure ()
    return (out, Grpc.Status.ok)
  let s := Grpc.Server.empty |>.registerBidi svc method h
  let sdsNote := if certPath?.isSome then "/SDS" else ""
  IO.println
    s!"FakeAds (LDS/RDS/CDS/EDS{sdsNote}) on 127.0.0.1:{port} → {endpoint} (cluster={cluster}, route={routeConfigName})"
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
