/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace Grpc.Resolver

structure Address where
  host : String
  port : UInt16
  deriving Inhabited, BEq

private def splitHostPort (t : String) : String × Option String :=
  let cs := t.toList
  match cs.reverse.findIdx? (· == ':') with
  | none => (t, none)
  | some ri =>
    let i := cs.length - 1 - ri
    let host := String.ofList (cs.take i)
    let port := String.ofList (cs.drop (i + 1))
    (host, some port)

/-- Parse `dns:///host:port`, `host:port`, or `host`. -/
def parseTarget (target : String) : Except String Address := do
  let t : String :=
    if "dns:///".isPrefixOf target then (target.drop "dns:///".length).toString
    else if "dns://".isPrefixOf target then (target.drop "dns://".length).toString
    else target
  let (host, port?) := splitHostPort t
  if host.length == 0 then throw "empty host"
  match port? with
  | none => pure { host, port := 443 }
  | some portS =>
    match portS.toNat? with
    | none => throw "bad port"
    | some p => pure { host, port := p.toUInt16 }

private def isAsciiWs (c : Char) : Bool := c == ' ' || c == '\t' || c == '\r'

private def splitWs (s : String) : Array String :=
  Id.run do
    let mut out : Array String := #[]
    let mut cur := ""
    for c in s.toList do
      if isAsciiWs c then
        if !cur.isEmpty then
          out := out.push cur
          cur := ""
      else
        cur := cur.push c
    if !cur.isEmpty then out := out.push cur
    return out

private def trimAsciiWs (s : String) : String :=
  let cs := s.toList.dropWhile isAsciiWs
  String.ofList (cs.reverse.dropWhile isAsciiWs).reverse

/-- Resolve every distinct A/AAAA record for `host` via the system resolver
    (`getent ahosts`, glibc's NSS-aware front-end to `getaddrinfo`). Returns
    `#[]` on any failure (missing tool, NXDOMAIN, sandboxed environment, …) so
    callers can fall back to the literal host. -/
private def resolveMultiIP (host : String) (port : UInt16) : IO (Array Address) := do
  try
    let out ← IO.Process.output { cmd := "getent", args := #["ahosts", host] }
    if out.exitCode != 0 then return #[]
    let mut seen : Array String := #[]
    let mut addrs : Array Address := #[]
    for line in out.stdout.splitOn "\n" do
      match (splitWs line)[0]? with
      | none => pure ()
      | some ip =>
        if !(seen.any (· == ip)) then
          seen := seen.push ip
          addrs := addrs.push { host := ip, port }
    return addrs
  catch _ =>
    return #[]

/-- Deterministic resolver override for tests/CI: `LEAN_GRPC_RESOLVE_ADDRS` is a
    comma-separated `host:port` list. Requires `LEAN_GRPC_ALLOW_RESOLVE_OVERRIDE=1`. -/
def resolveEnvOverride : IO (Option (Array Address)) := do
  match ← IO.getEnv "LEAN_GRPC_RESOLVE_ADDRS" with
  | none => pure none
  | some s =>
    match ← IO.getEnv "LEAN_GRPC_ALLOW_RESOLVE_OVERRIDE" with
    | some "1" =>
      IO.eprintln "WARN: LEAN_GRPC_RESOLVE_ADDRS override active"
      let mut addrs : Array Address := #[]
      for part in s.splitOn "," do
        let p := trimAsciiWs part
        if !p.isEmpty then
          match parseTarget p with
          | .ok a => addrs := addrs.push a
          | .error _ => pure ()
      pure (if addrs.isEmpty then none else some addrs)
    | _ =>
      IO.eprintln "WARN: LEAN_GRPC_RESOLVE_ADDRS ignored (set LEAN_GRPC_ALLOW_RESOLVE_OVERRIDE=1)"
      pure none

/-- Resolve a dial target to one or more addresses:
    1. `LEAN_GRPC_RESOLVE_ADDRS` override (deterministic, test-friendly).
    2. Multi-IP DNS via `getent ahosts` (enables round-robin across all A/AAAA records).
    3. Single literal address (libc DNS resolves it lazily at connect time). -/
def resolve (target : String) : IO (Array Address) := do
  if let some addrs ← resolveEnvOverride then
    return addrs
  let addr ← IO.ofExcept (parseTarget target)
  let multi ← resolveMultiIP addr.host addr.port
  if multi.isEmpty then return #[addr]
  return multi

end Grpc.Resolver
