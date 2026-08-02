/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Proto.WellKnown
import Bytes.Slice
import Grpc.Resolver
import Grpc.Tls

namespace Grpc.Xds.Discovery

/-- `envoy.service.discovery.v3.DiscoveryRequest` (subset, incl. `error_detail` for NACK). -/
structure Request where
  versionInfo : String := ""
  resourceNames : Array String := #[]
  typeUrl : String := ""
  responseNonce : String := ""
  /-- Set on NACK: client-detected error applying the last response of this type. -/
  errorDetail : Option Proto.WellKnown.RpcStatus := none
  deriving Inhabited

def Request.encode (r : Request) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.versionInfo.isEmpty then
      acc := Proto.Wire.encodeString acc 1 r.versionInfo
    for name in r.resourceNames do
      acc := Proto.Wire.encodeString acc 3 name
    if !r.typeUrl.isEmpty then
      acc := Proto.Wire.encodeString acc 4 r.typeUrl
    if !r.responseNonce.isEmpty then
      acc := Proto.Wire.encodeString acc 5 r.responseNonce
    if let some ed := r.errorDetail then
      acc := Proto.Wire.encodeMessage acc 6 (Proto.WellKnown.RpcStatus.encode ed)
    return acc

def Request.decode (b : ByteArray) : Except String Request := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let mut names : Array String := #[]
  for payload in Proto.Wire.fieldBytesMany fields 3 do
    match String.fromUTF8? payload with
    | some s => names := names.push s
    | none => pure ()
  let errorDetail :=
    match Proto.Wire.fieldBytes? fields 6 with
    | some ed =>
      match Proto.WellKnown.RpcStatus.decode ed with
      | .ok s => some s
      | .error _ => none
    | none => none
  return {
    versionInfo := (Proto.Wire.fieldString? fields 1).getD ""
    resourceNames := names
    typeUrl := (Proto.Wire.fieldString? fields 4).getD ""
    responseNonce := (Proto.Wire.fieldString? fields 5).getD ""
    errorDetail
  }

/-- Build an ACK request: echoes the accepted `version`/`nonce` for `typeUrl`. -/
def Request.ack (typeUrl version nonce : String) (resourceNames : Array String := #[]) : Request :=
  { typeUrl, versionInfo := version, responseNonce := nonce, resourceNames, errorDetail := none }

/-- Build a NACK request: keeps the last-accepted `version` (does not advance), echoes the
    rejected response's `nonce`, and carries `error_detail` describing why it was rejected. -/
def Request.nack (typeUrl version nonce message : String) (resourceNames : Array String := #[])
    (code : Int32 := 13 /- INTERNAL -/) : Request :=
  { typeUrl, versionInfo := version, responseNonce := nonce, resourceNames
    errorDetail := some { code, message } }

/-- `envoy.service.discovery.v3.DiscoveryResponse` (subset). -/
structure Response where
  versionInfo : String := "1"
  resources : Array Proto.WellKnown.AnyMsg := #[]
  typeUrl : String := ""
  nonce : String := "1"
  deriving Inhabited

def Response.encode (r : Response) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.versionInfo.isEmpty then
      acc := Proto.Wire.encodeString acc 1 r.versionInfo
    for a in r.resources do
      acc := Proto.Wire.encodeMessage acc 2 (Proto.WellKnown.AnyMsg.encode a)
    if !r.typeUrl.isEmpty then
      acc := Proto.Wire.encodeString acc 4 r.typeUrl
    if !r.nonce.isEmpty then
      acc := Proto.Wire.encodeString acc 5 r.nonce
    return acc

def Response.decode (b : ByteArray) : Except String Response := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let mut resources : Array Proto.WellKnown.AnyMsg := #[]
  for payload in Proto.Wire.fieldBytesMany fields 2 do
    resources := resources.push (← Proto.WellKnown.AnyMsg.decode payload)
  return {
    versionInfo := (Proto.Wire.fieldString? fields 1).getD ""
    resources
    typeUrl := (Proto.Wire.fieldString? fields 4).getD ""
    nonce := (Proto.Wire.fieldString? fields 5).getD ""
  }

/-- Minimal `envoy.config.endpoint.v3.ClusterLoadAssignment` for one host:port. -/
def encodeClusterLoadAssignment (cluster host : String) (port : UInt32) : ByteArray :=
  Id.run do
    let mut sock := ByteArray.empty
    sock := Proto.Wire.encodeString sock 1 host
    sock := Proto.Wire.encodeUInt32 sock 2 port
    let addr := Proto.Wire.encodeMessage ByteArray.empty 1 sock
    let endpoint := Proto.Wire.encodeMessage ByteArray.empty 1 addr
    let lb := Proto.Wire.encodeMessage ByteArray.empty 1 endpoint
    let loc := Proto.Wire.encodeMessage ByteArray.empty 2 lb
    let mut cla := ByteArray.empty
    cla := Proto.Wire.encodeString cla 1 cluster
    cla := Proto.Wire.encodeMessage cla 2 loc
    return cla

/-- Decode SocketAddress { address=1, port_value=2 }. -/
def decodeSocketAddress (b : ByteArray) : Option Resolver.Address :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => none
  | .ok fields =>
    match Proto.Wire.fieldString? fields 1, Proto.Wire.fieldUInt32? fields 2 with
    | some host, some port =>
      if host.isEmpty then none
      else some { host, port := port.toUInt16 }
    | _, _ => none

/-- Decode CLA → endpoints (follows nested LbEndpoint/Endpoint/Address/SocketAddress). -/
def parseClusterLoadAssignment (b : ByteArray) : Array Resolver.Address :=
  Id.run do
    let mut out : Array Resolver.Address := #[]
    match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
    | .error _ => return #[]
    | .ok claFields =>
      -- endpoints = field 2 (LocalityLbEndpoints)
      for locBytes in Proto.Wire.fieldBytesMany claFields 2 do
        match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray locBytes) with
        | .error _ => pure ()
        | .ok locFields =>
          -- lb_endpoints = field 2
          for lbBytes in Proto.Wire.fieldBytesMany locFields 2 do
            match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray lbBytes) with
            | .error _ => pure ()
            | .ok lbFields =>
              -- endpoint = field 1
              for epBytes in Proto.Wire.fieldBytesMany lbFields 1 do
                match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray epBytes) with
                | .error _ => pure ()
                | .ok epFields =>
                  -- address = field 1
                  for addrBytes in Proto.Wire.fieldBytesMany epFields 1 do
                    match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray addrBytes) with
                    | .error _ => pure ()
                    | .ok addrFields =>
                      -- socket_address = field 1
                      for sockBytes in Proto.Wire.fieldBytesMany addrFields 1 do
                        if let some a := decodeSocketAddress sockBytes then
                          out := out.push a
      return out

/-- Extract endpoints from a DiscoveryResponse containing CLA Anys. -/
def endpointsFromResponse (resp : Response) : Array Resolver.Address :=
  Id.run do
    let mut out : Array Resolver.Address := #[]
    for a in resp.resources do
      out := out ++ parseClusterLoadAssignment a.value
    return out

/-- Build EDS DiscoveryResponse for one cluster → host:port. -/
def edsResponse (cluster hostPort : String) : Except String Response := do
  let addr ← Resolver.parseTarget hostPort
  let cla := encodeClusterLoadAssignment cluster addr.host addr.port.toUInt32
  let any : Proto.WellKnown.AnyMsg := {
    typeUrl := "type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment"
    value := cla
  }
  return {
    versionInfo := "1"
    resources := #[any]
    typeUrl := "type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment"
    nonce := "1"
  }

/-! # CDS — `envoy.config.cluster.v3.Cluster` (subset). -/

/-- Cluster { name = 1; eds_cluster_config { service_name = 2 } = 3 }. -/
structure Cluster where
  name : String := ""
  /-- Falls back to `name` when the cluster does not carry a distinct `eds_cluster_config`. -/
  edsServiceName : String := ""
  deriving Inhabited

def Cluster.encode (c : Cluster) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !c.name.isEmpty then acc := Proto.Wire.encodeString acc 1 c.name
    if !c.edsServiceName.isEmpty && c.edsServiceName != c.name then
      let edsCfg := Proto.Wire.encodeString ByteArray.empty 2 c.edsServiceName
      acc := Proto.Wire.encodeMessage acc 3 edsCfg
    return acc

def Cluster.decode (b : ByteArray) : Except String Cluster := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let name := (Proto.Wire.fieldString? fields 1).getD ""
  let edsServiceName :=
    match Proto.Wire.fieldBytes? fields 3 with
    | some edsCfgBytes =>
      match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray edsCfgBytes) with
      | .ok edsFields => (Proto.Wire.fieldString? edsFields 2).getD name
      | .error _ => name
    | none => name
  return { name, edsServiceName }

/-! # RDS — `envoy.config.route.v3.RouteConfiguration` (subset). -/

/-- RouteMatch { prefix = 1 } (path_specifier oneof, prefix-only subset). -/
structure RouteMatch where
  pathPrefix : String := "/"
  deriving Inhabited

/-- RouteAction { cluster = 1 } (cluster_specifier oneof, single-cluster subset). -/
structure RouteAction where
  cluster : String := ""
  deriving Inhabited

/-- Route { match = 1; route = 2 } (action oneof, route-to-cluster subset). -/
structure Route where
  routeMatch : RouteMatch := {}
  route : RouteAction := {}
  deriving Inhabited

/-- VirtualHost { name = 1; domains = 2; routes = 3 }. -/
structure VirtualHost where
  name : String := ""
  domains : Array String := #[]
  routes : Array Route := #[]
  deriving Inhabited

/-- RouteConfiguration { name = 1; virtual_hosts = 4 }. -/
structure RouteConfiguration where
  name : String := ""
  virtualHosts : Array VirtualHost := #[]
  deriving Inhabited

def RouteMatch.encode (m : RouteMatch) : ByteArray :=
  if m.pathPrefix.isEmpty then ByteArray.empty
  else Proto.Wire.encodeString ByteArray.empty 1 m.pathPrefix

def RouteMatch.decode (b : ByteArray) : RouteMatch :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => {}
  | .ok fields => { pathPrefix := (Proto.Wire.fieldString? fields 1).getD "/" }

def RouteAction.encode (a : RouteAction) : ByteArray :=
  if a.cluster.isEmpty then ByteArray.empty else Proto.Wire.encodeString ByteArray.empty 1 a.cluster

def RouteAction.decode (b : ByteArray) : RouteAction :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => {}
  | .ok fields => { cluster := (Proto.Wire.fieldString? fields 1).getD "" }

def Route.encode (r : Route) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeMessage acc 1 (RouteMatch.encode r.routeMatch)
    acc := Proto.Wire.encodeMessage acc 2 (RouteAction.encode r.route)
    return acc

def Route.decode (b : ByteArray) : Route :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => {}
  | .ok fields =>
    { routeMatch := (Proto.Wire.fieldBytes? fields 1).map RouteMatch.decode |>.getD {}
      route := (Proto.Wire.fieldBytes? fields 2).map RouteAction.decode |>.getD {} }

def VirtualHost.encode (v : VirtualHost) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !v.name.isEmpty then acc := Proto.Wire.encodeString acc 1 v.name
    for d in v.domains do acc := Proto.Wire.encodeString acc 2 d
    for r in v.routes do acc := Proto.Wire.encodeMessage acc 3 (Route.encode r)
    return acc

def VirtualHost.decode (b : ByteArray) : VirtualHost :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => {}
  | .ok fields =>
    Id.run do
      let mut domains : Array String := #[]
      for d in Proto.Wire.fieldBytesMany fields 2 do
        match String.fromUTF8? d with
        | some s => domains := domains.push s
        | none => pure ()
      return {
        name := (Proto.Wire.fieldString? fields 1).getD ""
        domains
        routes := (Proto.Wire.fieldBytesMany fields 3).map Route.decode
      }

def RouteConfiguration.encode (rc : RouteConfiguration) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !rc.name.isEmpty then acc := Proto.Wire.encodeString acc 1 rc.name
    for vh in rc.virtualHosts do acc := Proto.Wire.encodeMessage acc 4 (VirtualHost.encode vh)
    return acc

def RouteConfiguration.decode (b : ByteArray) : Except String RouteConfiguration := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    name := (Proto.Wire.fieldString? fields 1).getD ""
    virtualHosts := (Proto.Wire.fieldBytesMany fields 4).map VirtualHost.decode
  }

/-- First non-empty `route.cluster` across all virtual hosts (simple "match everything" lookup;
    full domain/prefix matching is out of scope for this minimal subset). -/
def RouteConfiguration.firstClusterName? (rc : RouteConfiguration) : Option String :=
  Id.run do
    for vh in rc.virtualHosts do
      for r in vh.routes do
        if !r.route.cluster.isEmpty then return some r.route.cluster
    return none

/-! # LDS — `envoy.config.listener.v3.Listener` (subset).
    Only the client-side `api_listener` path (used by gRPC's own xDS resolution) is decoded;
    server-side `filter_chains` are walked as a fallback for the same embedded
    HttpConnectionManager → Rds shape. -/

structure Listener where
  name : String := ""
  routeConfigName : Option String := none
  deriving Inhabited

private def hcmTypeUrl : String :=
  "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager"

/-- HttpConnectionManager.rds.route_config_name (rds = 3, route_config_name = 2). -/
private def decodeHcmRdsName (hcmBytes : ByteArray) : Option String :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray hcmBytes) with
  | .error _ => none
  | .ok fields =>
    match Proto.Wire.fieldBytes? fields 3 with
    | some rdsBytes =>
      match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray rdsBytes) with
      | .ok rdsFields => Proto.Wire.fieldString? rdsFields 2
      | .error _ => none
    | none => none

private def routeConfigNameFromAny (anyBytes : ByteArray) : Option String :=
  match Proto.WellKnown.AnyMsg.decode anyBytes with
  | .ok any => decodeHcmRdsName any.value
  | .error _ => none

/-- ApiListener.api_listener (google.protobuf.Any, field 1). -/
private def routeConfigNameFromApiListener (apiListenerBytes : ByteArray) : Option String :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray apiListenerBytes) with
  | .error _ => none
  | .ok fields =>
    match Proto.Wire.fieldBytes? fields 1 with
    | some anyBytes => routeConfigNameFromAny anyBytes
    | none => none

/-- FilterChain.filters[].typed_config (google.protobuf.Any, field 4). -/
private def routeConfigNameFromFilterChains (fields : Array Proto.Wire.Field) : Option String :=
  Id.run do
    for fcBytes in Proto.Wire.fieldBytesMany fields 3 do
      match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray fcBytes) with
      | .error _ => pure ()
      | .ok fcFields =>
        for filterBytes in Proto.Wire.fieldBytesMany fcFields 3 do
          match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray filterBytes) with
          | .error _ => pure ()
          | .ok filterFields =>
            match Proto.Wire.fieldBytes? filterFields 4 with
            | some anyBytes =>
              match routeConfigNameFromAny anyBytes with
              | some n => return some n
              | none => pure ()
            | none => pure ()
    return none

def Listener.encode (l : Listener) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !l.name.isEmpty then acc := Proto.Wire.encodeString acc 1 l.name
    if let some routeConfigName := l.routeConfigName then
      let mut rds := ByteArray.empty
      rds := Proto.Wire.encodeString rds 2 routeConfigName
      let mut hcm := ByteArray.empty
      hcm := Proto.Wire.encodeMessage hcm 3 rds
      let any := Proto.WellKnown.AnyMsg.encode { typeUrl := hcmTypeUrl, value := hcm }
      let mut apiListener := ByteArray.empty
      apiListener := Proto.Wire.encodeMessage apiListener 1 any
      acc := Proto.Wire.encodeMessage acc 19 apiListener
    return acc

def Listener.decode (b : ByteArray) : Except String Listener := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let name := (Proto.Wire.fieldString? fields 1).getD ""
  let routeConfigName :=
    match Proto.Wire.fieldBytes? fields 19 with
    | some apiListenerBytes =>
      match routeConfigNameFromApiListener apiListenerBytes with
      | some n => some n
      | none => routeConfigNameFromFilterChains fields
    | none => routeConfigNameFromFilterChains fields
  return { name, routeConfigName }

/-! # SDS — `envoy.extensions.transport_sockets.tls.v3.Secret` (subset).
    Only `tls_certificate` with filename-backed `DataSource`s is supported: enough to hand
    file paths to `Grpc.Tls.Config` when a control plane pushes cert/key locations. -/

structure Secret where
  name : String := ""
  certPath : Option String := none
  keyPath : Option String := none
  deriving Inhabited

private def encodeDataSourceFilename (path : String) : ByteArray :=
  Proto.Wire.encodeString ByteArray.empty 1 path

private def decodeDataSourceFilename (b : ByteArray) : Option String :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => none
  | .ok fields => Proto.Wire.fieldString? fields 1

def Secret.encode (s : Secret) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !s.name.isEmpty then acc := Proto.Wire.encodeString acc 1 s.name
    match s.certPath, s.keyPath with
    | some cert, some key =>
      let mut tlsCert := ByteArray.empty
      tlsCert := Proto.Wire.encodeMessage tlsCert 1 (encodeDataSourceFilename cert)
      tlsCert := Proto.Wire.encodeMessage tlsCert 2 (encodeDataSourceFilename key)
      acc := Proto.Wire.encodeMessage acc 2 tlsCert
    | _, _ => pure ()
    return acc

def Secret.decode (b : ByteArray) : Except String Secret := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let name := (Proto.Wire.fieldString? fields 1).getD ""
  let (certPath, keyPath) :=
    match Proto.Wire.fieldBytes? fields 2 with
    | some tlsCertBytes =>
      match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray tlsCertBytes) with
      | .error _ => (none, none)
      | .ok tlsFields =>
        ((Proto.Wire.fieldBytes? tlsFields 1).bind decodeDataSourceFilename,
         (Proto.Wire.fieldBytes? tlsFields 2).bind decodeDataSourceFilename)
    | none => (none, none)
  return { name, certPath, keyPath }

/-- True when `p` is an absolute path under `root` with no `..` segments. -/
def sdsPathAllowed (p : String) (root : String) : Bool :=
  let root :=
    if root.endsWith "/" then (root.dropEnd 1).toString else root
  !p.isEmpty && p.startsWith "/" && !(p.splitOn "/").contains ".." &&
    !p.any (· == Char.ofNat 0) &&
    (p == root || p.startsWith (root ++ "/"))

/-- Overlay a decoded `Secret`'s cert/key paths onto a `Grpc.Tls.Config`
    (existing `base` fields win when the secret doesn't carry a given path).
    Paths must be absolute under `LEAN_GRPC_SDS_ROOT` (default `/var/run/secrets`). -/
def Secret.toTlsConfig (s : Secret) (base : Grpc.Tls.Config := {}) : IO Grpc.Tls.Config := do
  let root := (← IO.getEnv "LEAN_GRPC_SDS_ROOT").getD "/var/run/secrets"
  let check (label : String) (p? : Option String) : IO (Option System.FilePath) := do
    match p? with
    | none => pure none
    | some p =>
      if sdsPathAllowed p root then pure (some (System.FilePath.mk p))
      else throw (IO.userError s!"SDS {label} path rejected (must be under {root}): {p}")
  let cert ← check "cert" s.certPath
  let key ← check "key" s.keyPath
  return { base with
      certPath := base.certPath.orElse (fun _ => cert)
      keyPath := base.keyPath.orElse (fun _ => key) }

/-! # Typed DiscoveryResponse builders (used by test fixtures / FakeAds). -/

/-- Build a CDS DiscoveryResponse for a single cluster (EDS-backed by the same name). -/
def cdsResponse (clusterName : String) (edsServiceName : String := "") : Response :=
  let cluster : Cluster := { name := clusterName, edsServiceName := edsServiceName }
  let any : Proto.WellKnown.AnyMsg :=
    { typeUrl := "type.googleapis.com/envoy.config.cluster.v3.Cluster", value := Cluster.encode cluster }
  { versionInfo := "1", resources := #[any]
    typeUrl := "type.googleapis.com/envoy.config.cluster.v3.Cluster", nonce := "1" }

/-- Build an RDS DiscoveryResponse with one virtual host matching everything → `clusterName`. -/
def rdsResponse (routeConfigName clusterName : String) : Response :=
  let rc : RouteConfiguration := {
    name := routeConfigName
    virtualHosts := #[{
      name := s!"{routeConfigName}-vhost"
      domains := #["*"]
      routes := #[{ routeMatch := { pathPrefix := "/" }, route := { cluster := clusterName } }]
    }]
  }
  let any : Proto.WellKnown.AnyMsg :=
    { typeUrl := "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"
      value := RouteConfiguration.encode rc }
  { versionInfo := "1", resources := #[any]
    typeUrl := "type.googleapis.com/envoy.config.route.v3.RouteConfiguration", nonce := "1" }

/-- Build an LDS DiscoveryResponse: listener `listenerName` → RDS `routeConfigName`. -/
def ldsResponse (listenerName routeConfigName : String) : Response :=
  let l : Listener := { name := listenerName, routeConfigName := some routeConfigName }
  let any : Proto.WellKnown.AnyMsg :=
    { typeUrl := "type.googleapis.com/envoy.config.listener.v3.Listener", value := Listener.encode l }
  { versionInfo := "1", resources := #[any]
    typeUrl := "type.googleapis.com/envoy.config.listener.v3.Listener", nonce := "1" }

/-- Build an SDS DiscoveryResponse handing back filename-backed cert/key paths. -/
def sdsResponse (secretName certPath keyPath : String) : Response :=
  let s : Secret := { name := secretName, certPath := some certPath, keyPath := some keyPath }
  let any : Proto.WellKnown.AnyMsg :=
    { typeUrl := "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"
      value := Secret.encode s }
  { versionInfo := "1", resources := #[any]
    typeUrl := "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret", nonce := "1" }

end Grpc.Xds.Discovery
