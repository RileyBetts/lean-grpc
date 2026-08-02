/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Resolver

namespace Grpc.Xds

/-- EDS-ish type URL used in lean-grpc ADS subset. -/
def edsTypeUrl : String :=
  "type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment"

/-- CDS type URL. -/
def cdsTypeUrl : String :=
  "type.googleapis.com/envoy.config.cluster.v3.Cluster"

/-- LDS type URL. -/
def ldsTypeUrl : String :=
  "type.googleapis.com/envoy.config.listener.v3.Listener"

/-- RDS type URL. -/
def rdsTypeUrl : String :=
  "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"

/-- SDS type URL. -/
def sdsTypeUrl : String :=
  "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"

/-- Minimal xDS bootstrap: static clusters and/or ADS servers. -/
structure Bootstrap where
  /-- Map from authority/resource name → addresses. -/
  clusters : Array (String × Array Resolver.Address) := #[]
  /-- ADS management servers (`server_uri`). -/
  xdsServers : Array Resolver.Address := #[]
  deriving Inhabited

/-- Pull `"server_uri":"host:port"` entries. -/
private def parseServerUris (json : String) : Array Resolver.Address :=
  Id.run do
    let mut out : Array Resolver.Address := #[]
    let needle := "\"server_uri\""
    let ncs := needle.toList.toArray
    let cs := json.toList.toArray
    let mut i := 0
    while i + ncs.size ≤ cs.size do
      let mut ok := true
      for j in [:ncs.size] do
        if cs[i + j]! != ncs[j]! then ok := false
      if ok then
        let mut k := i + ncs.size
        while k < cs.size && (cs[k]! == ' ' || cs[k]! == ':' || cs[k]! == '\t') do
          k := k + 1
        if k < cs.size && cs[k]! == '"' then
          k := k + 1
          let mut hostport := ""
          while k < cs.size && cs[k]! != '"' do
            hostport := hostport.push cs[k]!
            k := k + 1
          match Resolver.parseTarget hostport with
          | .ok a => out := out.push a
          | .error _ => pure ()
        i := k
      else
        i := i + 1
    return out

/-- Parse a tiny bootstrap JSON subset:
    `{"xds_servers":[{"server_uri":"127.0.0.1:18000"}],"clusters":{"foo":["127.0.0.1:10000"]}}` -/
def parseBootstrap (json : String) : Bootstrap :=
  Id.run do
    let mut clusters : Array (String × Array Resolver.Address) := #[]
    let cs := json.toList.toArray
    let mut i := 0
    while i + 3 < cs.size do
      if cs[i]! == '"' then
        let mut j := i + 1
        let mut name := ""
        while j < cs.size && cs[j]! != '"' do
          name := name.push cs[j]!
          j := j + 1
        let mut k := j + 1
        while k < cs.size && (cs[k]! == ' ' || cs[k]! == ':' || cs[k]! == '\n' || cs[k]! == '\t') do
          k := k + 1
        if k < cs.size && cs[k]! == '[' then
          let mut addrs : Array Resolver.Address := #[]
          let mut p := k + 1
          while p < cs.size && cs[p]! != ']' do
            if cs[p]! == '"' then
              p := p + 1
              let mut hostport := ""
              while p < cs.size && cs[p]! != '"' do
                hostport := hostport.push cs[p]!
                p := p + 1
              match Resolver.parseTarget hostport with
              | .ok a => addrs := addrs.push a
              | .error _ => pure ()
            p := p + 1
          if !name.isEmpty && !addrs.isEmpty && name != "clusters" && name != "xds_servers" then
            clusters := clusters.push (name, addrs)
          i := p
        else
          i := j + 1
      else
        i := i + 1
    return { clusters, xdsServers := parseServerUris json }

def loadBootstrapFile (path : System.FilePath) : IO Bootstrap := do
  let text ← IO.FS.readFile path
  return parseBootstrap text

/-- Resolve `xds:///name` via bootstrap static clusters. -/
def resolve (bootstrap : Bootstrap) (target : String) : Except String (Array Resolver.Address) := do
  let name ←
    if "xds:///".isPrefixOf target then
      pure (target.drop "xds:///".length).toString
    else throw "not an xds:/// target"
  for (n, addrs) in bootstrap.clusters do
    if n == name then return addrs
  throw s!"xds cluster not found: {name}"

/-- Extract `"endpoints":["host:port",...]` from ADS JSON response. -/
def parseEndpointsJson (json : String) : Array Resolver.Address :=
  Id.run do
    let mut addrs : Array Resolver.Address := #[]
    let needle := "\"endpoints\""
    let ncs := needle.toList.toArray
    let cs := json.toList.toArray
    let mut i := 0
    while i + ncs.size ≤ cs.size do
      let mut ok := true
      for j in [:ncs.size] do
        if cs[i + j]! != ncs[j]! then ok := false
      if ok then
        let mut k := i + ncs.size
        while k < cs.size && (cs[k]! == ' ' || cs[k]! == ':' || cs[k]! == '\t') do
          k := k + 1
        if k < cs.size && cs[k]! == '[' then
          let mut p := k + 1
          while p < cs.size && cs[p]! != ']' do
            if cs[p]! == '"' then
              p := p + 1
              let mut hostport := ""
              while p < cs.size && cs[p]! != '"' do
                hostport := hostport.push cs[p]!
                p := p + 1
              match Resolver.parseTarget hostport with
              | .ok a => addrs := addrs.push a
              | .error _ => pure ()
            p := p + 1
          return addrs
        i := k
      else
        i := i + 1
    return addrs

/-- Cluster name from `xds:///name`. -/
def clusterName (target : String) : Except String String :=
  if "xds:///".isPrefixOf target then
    .ok (target.drop "xds:///".length).toString
  else
    .error "not an xds:/// target"

/-- Static-only env resolve (no ADS). Prefer `Grpc.XdsAds.resolveFromEnv`. -/
def resolveFromEnv (target : String) : IO (Array Resolver.Address) := do
  match ← IO.getEnv "LEAN_GRPC_XDS_BOOTSTRAP" with
  | none => throw (IO.userError "LEAN_GRPC_XDS_BOOTSTRAP not set")
  | some path =>
    let boot ← loadBootstrapFile path
    IO.ofExcept (resolve boot target)

end Grpc.Xds
