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

/-- Resolve via getaddrinfo-style: for now returns the literal host (libc DNS at connect time). -/
def resolve (target : String) : IO (Array Address) := do
  let addr ← IO.ofExcept (parseTarget target)
  return #[addr]

end Grpc.Resolver
