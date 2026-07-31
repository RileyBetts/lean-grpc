/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Proto.WellKnown
import Bytes.Slice
import Grpc.Resolver

namespace Grpc.Xds.Discovery

/-- `envoy.service.discovery.v3.DiscoveryRequest` (subset). -/
structure Request where
  versionInfo : String := ""
  resourceNames : Array String := #[]
  typeUrl : String := ""
  responseNonce : String := ""
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
    return acc

def Request.decode (b : ByteArray) : Except String Request := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let mut names : Array String := #[]
  for payload in Proto.Wire.fieldBytesMany fields 3 do
    match String.fromUTF8? payload with
    | some s => names := names.push s
    | none => pure ()
  return {
    versionInfo := (Proto.Wire.fieldString? fields 1).getD ""
    resourceNames := names
    typeUrl := (Proto.Wire.fieldString? fields 4).getD ""
    responseNonce := (Proto.Wire.fieldString? fields 5).getD ""
  }

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

end Grpc.Xds.Discovery
