/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.Wire
import Bytes.Slice
import H2
import Hpack
import Grpc.Metadata
import Grpc.Stream
import Grpc.Resolver
import Grpc.Tls

/-! # grpclb — thin client-side `grpc.lb.v1.LoadBalancer/BalanceLoad` shim.

    xDS (`Grpc.XdsAds`) is the preferred/modern service-mesh discovery+load-balancing path in
    this library; grpclb is the older protocol still used by some balancers (e.g. legacy GCP
    load balancers) that return a plain server list (with per-server "drop" entries for
    client-side rate limiting) rather than full xDS resources. This is a small working shim
    covering the common case: connect to a balancer address, send one `InitialLoadBalanceRequest`,
    and pick round-robin from the first `ServerList` response (honoring `drop` entries). Periodic
    `ClientStats` reporting and balancer-pushed list refresh are out of scope for this minimal
    subset. -/
namespace Grpc.Grpclb

private def lbHeaders (host : String) (useHttps : Bool) : Array Hpack.HeaderField :=
  #[
    Metadata.methodPost,
    if useHttps then Metadata.schemeHttps else Metadata.schemeHttp,
    ⟨Metadata.ascii ":authority", Metadata.ascii host⟩,
    Metadata.path "grpc.lb.v1.LoadBalancer" "BalanceLoad",
    Metadata.contentTypeGrpc,
    Metadata.teTrailers
  ]

/-- Cleartext grpclb only with `LEAN_GRPC_XDS_INSECURE=1` (shared test escape with ADS). -/
private def connectBalancer (balancer : Resolver.Address) : IO (H2.ClientConn × Bool) := do
  match ← IO.getEnv "LEAN_GRPC_XDS_INSECURE" with
  | some "1" =>
    IO.eprintln "WARN: LEAN_GRPC_XDS_INSECURE=1 → grpclb over cleartext h2c"
    pure (← H2.Client.connectH2c balancer.host balancer.port, false)
  | _ =>
    pure (← Grpc.Tls.connectH2 balancer.host balancer.port {}, true)

/-- One entry of `ServerList.servers`. `ipAddress` is the raw (4- or 16-byte) address as sent
    on the wire; `drop = true` means the client should locally fail/drop the call using this
    pick's `loadBalanceToken` rather than route it. -/
structure Server where
  ipAddress : ByteArray := ByteArray.empty
  port : UInt32 := 0
  loadBalanceToken : String := ""
  drop : Bool := false
  deriving Inhabited

private def decodeServer (b : ByteArray) : Server :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => {}
  | .ok fields =>
    { ipAddress := (Proto.Wire.fieldBytes? fields 1).getD ByteArray.empty
      port := (Proto.Wire.fieldUInt32? fields 2).getD 0
      loadBalanceToken := (Proto.Wire.fieldString? fields 3).getD ""
      drop := ((Proto.Wire.fieldUInt32? fields 4).getD 0) != 0 }

/-- `LoadBalanceResponse.server_list.servers` (field 2 of the oneof response, field 1 of
    `ServerList`). Ignores `initial_response`/`fallback_response` — this shim always treats
    the first server-list-bearing response as authoritative. -/
def decodeServerList (b : ByteArray) : Except String (Array Server) := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  match Proto.Wire.fieldBytes? fields 2 with
  | none => return #[]
  | some serverList =>
    let slFields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray serverList)
    return (Proto.Wire.fieldBytesMany slFields 1).map decodeServer

/-- `LoadBalanceRequest { initial_request: InitialLoadBalanceRequest { name } }`. -/
def initialRequest (name : String) : ByteArray :=
  let inner := Proto.Wire.encodeString ByteArray.empty 1 name
  Proto.Wire.encodeBytes ByteArray.empty 1 inner

/-- Render a raw IPv4 (4-byte) address as dotted-decimal; anything else (IPv6, malformed) is
    left as a `getent`-unfriendly-but-harmless hex fallback since `Resolver.Address.host` just
    needs to be something the H2 client can pass to the OS connector. -/
def ipAddressToHost (ip : ByteArray) : String :=
  if ip.size == 4 then
    s!"{ip.get! 0}.{ip.get! 1}.{ip.get! 2}.{ip.get! 3}"
  else
    Id.run do
      let mut s := ""
      for i in [:ip.size] do
        s := s ++ String.ofList (Nat.toDigits 16 (ip.get! i).toNat)
      return s

/-- Non-`drop` servers as dialable `Resolver.Address`es, in list order (round-robin over this
    array via `Grpc.Balancer` gives the standard grpclb client behavior for the common case). -/
def liveAddresses (servers : Array Server) : Array Resolver.Address :=
  servers.filterMap (fun s =>
    if s.drop then none
    else some { host := ipAddressToHost s.ipAddress, port := s.port.toUInt16 })

/-- Connect to a grpclb balancer, send the initial request, and return the first `ServerList`
    it streams back (already filtered to non-`drop` addresses via `liveAddresses`). One-shot:
    opens a fresh `BalanceLoad` stream, reads exactly one response, then half-closes. -/
def fetchServerList (balancer : Resolver.Address) (serviceName : String) :
    IO (Array Resolver.Address) := do
  let (conn, useHttps) ← connectBalancer balancer
  let stream ← Stream.openCall conn (lbHeaders balancer.host useHttps)
  Stream.StreamWriter.send stream.writer (initialRequest serviceName)
  Stream.StreamWriter.halfClose stream.writer
  match ← Stream.StreamReader.recv? stream.reader with
  | none => throw (IO.userError "grpclb: empty response")
  | some msg =>
    let servers ← IO.ofExcept (decodeServerList msg)
    let addrs := liveAddresses servers
    if addrs.isEmpty then
      throw (IO.userError s!"grpclb: no live servers (received {servers.size}, all dropped?)")
    return addrs

end Grpc.Grpclb
