/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.

LGSEC-2026-32: Replaced the ad-hoc string-scraper in `parseBootstrap` /
`parseServerUris` / `parseEndpointsJson` with a small state-machine JSON parser
that correctly handles arbitrary whitespace, field ordering, nested objects,
escaped characters in string values, and unterminated-value attacks.
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

/-! ## Minimal JSON state-machine (LGSEC-2026-32)

We parse only the subset of JSON needed for the xDS bootstrap schema.
The parser is character-position based and never backtracks unsafely. -/

/-- Minimal JSON value type for xDS bootstrap parsing. -/
private inductive JVal where
  | str (s : String)
  | arr (elems : Array JVal)
  | obj (fields : Array (String × JVal))
  | num (s : String)
  | bool (b : Bool)
  | null
  deriving Inhabited

private def isWs (c : Char) : Bool :=
  c == ' ' || c == '\t' || c == '\n' || c == '\r'

/-- Skip whitespace starting at `i`; return the index of the first non-WS char. -/
private def skipWs (cs : Array Char) (i : Nat) : Nat :=
  Id.run do
    let mut j := i
    while j < cs.size && isWs cs[j]! do
      j := j + 1
    return j

/-- Parse a JSON string starting at the opening `"` (cs[i] must be `"`).
    Handles `\"` escape.  Returns (string, next_index) or none on error. -/
private def parseString (cs : Array Char) (i : Nat) : Option (String × Nat) :=
  if i ≥ cs.size || cs[i]! != '"' then none
  else Id.run do
    let mut j := i + 1
    let mut s := ""
    let mut escape := false
    while j < cs.size do
      let c := cs[j]!
      if escape then
        match c with
        | '"'  => s := s.push '"'
        | '\\' => s := s.push '\\'
        | '/'  => s := s.push '/'
        | 'n'  => s := s.push '\n'
        | 'r'  => s := s.push '\r'
        | 't'  => s := s.push '\t'
        | _    => s := s.push c
        escape := false
      else if c == '\\' then
        escape := true
      else if c == '"' then
        return some (s, j + 1)
      else
        s := s.push c
      j := j + 1
    -- Unterminated string — return none (safe rejection).
    return none

private def parseVal (cs : Array Char) (i : Nat) (fuel : Nat) : Option (JVal × Nat) :=
  match fuel with
  | 0 => none
  | fuel' + 1 =>
    let i' := skipWs cs i
    if i' >= cs.size then none
    else
      let c := cs[i']!
      if c == '"' then
        parseString cs i' |>.map (fun (s, j) => (.str s, j))
      else if c == '[' then Id.run do
        let mut j := skipWs cs (i' + 1)
        let mut elems : Array JVal := #[]
        if j < cs.size && cs[j]! == ']' then
          return some (.arr #[], j + 1)
        let mut ok := true
        while ok && j < cs.size do
          match parseVal cs j fuel' with
          | none => ok := false
          | some (v, j') =>
            elems := elems.push v
            let j'' := skipWs cs j'
            if j'' < cs.size then
              if cs[j'']! == ',' then
                j := skipWs cs (j'' + 1)
              else if cs[j'']! == ']' then
                return some (.arr elems, j'' + 1)
              else
                ok := false
            else
              ok := false
        return none
      else if c == '{' then Id.run do
        let mut j := skipWs cs (i' + 1)
        let mut fields : Array (String × JVal) := #[]
        if j < cs.size && cs[j]! == '}' then
          return some (.obj #[], j + 1)
        let mut ok := true
        while ok && j < cs.size do
          match parseString cs j with
          | none => ok := false
          | some (key, j') =>
            let j'' := skipWs cs j'
            if j'' >= cs.size || cs[j'']! != ':' then
              ok := false
            else
              let j3 := skipWs cs (j'' + 1)
              match parseVal cs j3 fuel' with
              | none => ok := false
              | some (v, j4) =>
                fields := fields.push (key, v)
                let j5 := skipWs cs j4
                if j5 < cs.size then
                  if cs[j5]! == ',' then
                    j := skipWs cs (j5 + 1)
                  else if cs[j5]! == '}' then
                    return some (.obj fields, j5 + 1)
                  else
                    ok := false
                else
                  ok := false
        return none
      else if c == 't' && i' + 3 < cs.size &&
              cs[i'+1]! == 'r' && cs[i'+2]! == 'u' && cs[i'+3]! == 'e' then
        some (.bool true, i' + 4)
      else if c == 'f' && i' + 4 < cs.size &&
              cs[i'+1]! == 'a' && cs[i'+2]! == 'l' && cs[i'+3]! == 's' && cs[i'+4]! == 'e' then
        some (.bool false, i' + 5)
      else if c == 'n' && i' + 3 < cs.size &&
              cs[i'+1]! == 'u' && cs[i'+2]! == 'l' && cs[i'+3]! == 'l' then
        some (.null, i' + 4)
      else if c == '-' || (c.toNat >= '0'.toNat && c.toNat <= '9'.toNat) then Id.run do
        let mut j := i'
        while j < cs.size && (cs[j]!.isDigit || cs[j]! == '-' || cs[j]! == '.' ||
              cs[j]! == 'e' || cs[j]! == 'E' || cs[j]! == '+') do
          j := j + 1
        return some (.num (String.ofList (cs.extract i' j).toList), j)
      else none


/-- Parse a complete JSON value from a string with a recursion fuel limit. -/
private def parseJson (json : String) : Option JVal :=
  let cs := json.toList.toArray
  parseVal cs 0 1024 |>.map Prod.fst

/-! ## Bootstrap extraction from parsed JSON -/

/-- Collect `Resolver.Address` values from an array of strings. -/
private def addrsOfJsonArray (v : JVal) : Array Resolver.Address :=
  match v with
  | .arr elems =>
    elems.foldl (fun acc e =>
      match e with
      | .str s => match Resolver.parseTarget s with
        | .ok a => acc.push a
        | .error _ => acc
      | _ => acc) #[]
  | _ => #[]

/-- Extract `server_uri` addresses from a `xds_servers` array. -/
private def xdsServersOfJson (v : JVal) : Array Resolver.Address :=
  match v with
  | .arr elems =>
    elems.foldl (fun acc e =>
      match e with
      | .obj fields =>
        match fields.find? (·.1 == "server_uri") with
        | some (_, .str uri) =>
          match Resolver.parseTarget uri with
          | .ok a => acc.push a
          | .error _ => acc
        | _ => acc
      | _ => acc) #[]
  | _ => #[]

/-- Extract `clusters` map from the top-level object. -/
private def clustersOfJson (v : JVal) : Array (String × Array Resolver.Address) :=
  match v with
  | .obj fields =>
    fields.foldl (fun acc (k, v) =>
      let addrs := addrsOfJsonArray v
      if !k.isEmpty && !addrs.isEmpty then acc.push (k, addrs)
      else acc) #[]
  | _ => #[]

/-- Parse a tiny bootstrap JSON subset using the state-machine parser.
    Handles arbitrary field ordering, whitespace, and escaped strings.
    Example:
    `{"xds_servers":[{"server_uri":"127.0.0.1:18000"}],"clusters":{"foo":["127.0.0.1:10000"]}}` -/
def parseBootstrap (json : String) : Bootstrap :=
  match parseJson json with
  | none => {}  -- malformed JSON → empty bootstrap (safe default)
  | some (.obj fields) =>
    let xdsServers :=
      match fields.find? (·.1 == "xds_servers") with
      | some (_, v) => xdsServersOfJson v
      | none => #[]
    let clusters :=
      match fields.find? (·.1 == "clusters") with
      | some (_, v) => clustersOfJson v
      | none => #[]
    { xdsServers, clusters }
  | some _ => {}

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
  match parseJson json with
  | some (.obj fields) =>
    match fields.find? (·.1 == "endpoints") with
    | some (_, v) => addrsOfJsonArray v
    | none => #[]
  | _ => #[]

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
