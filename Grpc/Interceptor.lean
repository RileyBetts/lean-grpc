/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Server
import Grpc.Channel
import Grpc.PeerIdentity

/-! # Client/server interceptor chains for unary calls.

    An interceptor wraps a "next call" function so it can run logic before/after the wrapped
    call (logging, auth, metrics, retries, …) and optionally short-circuit it. Chains compose
    outermost-first: the first interceptor in the array is the outermost layer, so it sees the
    request first and the response/status last. -/
namespace Grpc.Interceptor

/-- Server-side unary interceptor: given the `service`/`method` being dispatched and the next
    handler in the chain, returns a (possibly wrapping) handler. -/
abbrev ServerUnary := String → String → UnaryHandler → UnaryHandler

/-- Fold a chain of server interceptors around `base`, outermost-first. -/
def applyServer (service method : String) (chain : Array ServerUnary) (base : UnaryHandler) :
    UnaryHandler :=
  chain.foldr (fun mw next => mw service method next) base

/-- Register a unary method on `s`, wrapped with `chain` (see `applyServer`). -/
def registerUnary (s : Server) (service method : String) (chain : Array ServerUnary)
    (h : UnaryHandler) : Server :=
  Server.register s service method (applyServer service method chain h)

/-- Context-aware server unary interceptor. -/
abbrev ServerUnaryWithContext :=
  String → String → UnaryHandlerWithContext → UnaryHandlerWithContext

/-- Fold a chain of context-aware server interceptors around `base`, outermost-first. -/
def applyServerWithContext (service method : String) (chain : Array ServerUnaryWithContext)
    (base : UnaryHandlerWithContext) : UnaryHandlerWithContext :=
  chain.foldr (fun mw next => mw service method next) base

/-- Register a context-aware unary method wrapped with `chain`. -/
def registerUnaryWithContext (s : Server) (service method : String)
    (chain : Array ServerUnaryWithContext) (h : UnaryHandlerWithContext) : Server :=
  Server.registerWithContext s service method (applyServerWithContext service method chain h)

/-- Fail closed under mTLS: when `ctx.mtlsRequired` and `peerIdentity` is missing, return
    `UNAUTHENTICATED` instead of invoking `next`. -/
def requirePeerIdentity : ServerUnaryWithContext := fun _service _method next ctx req => do
  if ctx.mtlsRequired && ctx.peerIdentity.isNone then
    return (ByteArray.empty, Status.unauthenticated "mtls_required")
  next ctx req

/-- Client-side unary invoker: request bytes → `CallResult` (matches `Channel.unary`'s core
    shape, modulo the extra dialing options `Channel.unary` takes). -/
abbrev ClientUnaryInvoker := ByteArray → IO CallResult

/-- Client-side unary interceptor: given the `service`/`method` being called and the next
    invoker in the chain, returns a (possibly wrapping) invoker. -/
abbrev ClientUnary := String → String → ClientUnaryInvoker → ClientUnaryInvoker

/-- Fold a chain of client interceptors around `base`, outermost-first. -/
def applyClient (service method : String) (chain : Array ClientUnary)
    (base : ClientUnaryInvoker) : ClientUnaryInvoker :=
  chain.foldr (fun mw next => mw service method next) base

/-- Call `service/method` on `ch` through an interceptor chain, otherwise identical to
    `Channel.unary`. -/
def callUnary (ch : Channel) (service method : String) (chain : Array ClientUnary)
    (req : ByteArray) : IO CallResult :=
  applyClient service method chain (fun r => Channel.unary ch service method r) req

/-- Ready-made server interceptor: appends one line per request and one per response/status to
    `sink` (see `Tests/OpsSmoke.lean` for a worked chain example). -/
def loggingServer (sink : IO.Ref (Array String)) : ServerUnary := fun service method next req => do
  sink.modify (·.push s!"> {service}/{method} req={req.size}B")
  let (resp, st) ← next req
  sink.modify (·.push s!"< {service}/{method} resp={resp.size}B status={st.code.toUInt32}")
  return (resp, st)

/-- Context-aware variant of `loggingServer` (logs peer CN when present). -/
def loggingServerWithContext (sink : IO.Ref (Array String)) : ServerUnaryWithContext :=
  fun service method next ctx req => do
    let peer :=
      match ctx.peerIdentity with
      | some id => id.commonName
      | none => "-"
    sink.modify (·.push s!"> {service}/{method} req={req.size}B peer={peer}")
    let (resp, st) ← next ctx req
    sink.modify (·.push s!"< {service}/{method} resp={resp.size}B status={st.code.toUInt32}")
    return (resp, st)

/-- Ready-made client interceptor: same as `loggingServer`, mirrored for the call site. -/
def loggingClient (sink : IO.Ref (Array String)) : ClientUnary := fun service method next req => do
  sink.modify (·.push s!"> {service}/{method} req={req.size}B")
  let res ← next req
  sink.modify (·.push s!"< {service}/{method} status={res.status.code.toUInt32}")
  return res

/-- Build an `authorization: Bearer <token>` metadata map. `ClientUnaryInvoker` only carries
    the request body (not metadata), so a bearer-token interceptor can't be expressed as a
    `ClientUnary` directly — build this alongside `Channel.unary`'s `metadata` argument
    instead (or extend `Channel.unary` calls inside a custom invoker passed to `callUnary`). -/
def bearerMetadata (token : String) : Metadata :=
  Metadata.empty.add "authorization" s!"Bearer {token}"

end Grpc.Interceptor
