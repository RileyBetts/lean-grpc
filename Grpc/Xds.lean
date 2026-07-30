/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Resolver

namespace Grpc.Xds

/-- Minimal xDS bootstrap: static endpoints for `xds:///name` targets (no ADS stream). -/
structure Bootstrap where
  /-- Map from authority/resource name → addresses. -/
  clusters : Array (String × Array Resolver.Address) := #[]
  deriving Inhabited

/-- Parse a tiny bootstrap JSON subset:
    `{"clusters":{"foo":["127.0.0.1:10000","127.0.0.1:10001"]}}` -/
def parseBootstrap (json : String) : Bootstrap :=
  Id.run do
    let mut clusters : Array (String × Array Resolver.Address) := #[]
    -- Very small scanner: find "name":[ "host:port", ... ]
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
          if !name.isEmpty && !addrs.isEmpty && name != "clusters" then
            clusters := clusters.push (name, addrs)
          i := p
        else
          i := j + 1
      else
        i := i + 1
    return { clusters }

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

/-- Dial helper env: `LEAN_GRPC_XDS_BOOTSTRAP` path. -/
def resolveFromEnv (target : String) : IO (Array Resolver.Address) := do
  match ← IO.getEnv "LEAN_GRPC_XDS_BOOTSTRAP" with
  | none => throw (IO.userError "LEAN_GRPC_XDS_BOOTSTRAP not set")
  | some path =>
    let boot ← loadBootstrapFile path
    IO.ofExcept (resolve boot target)

end Grpc.Xds
