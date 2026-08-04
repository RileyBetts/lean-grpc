# lean-grpc IAM requirements (from lean-compliance)

**Status:** working requirements handoff — not an official lean-compliance `docs/` claim.  
**Date:** 2026-08-04  
**Consumer:** lean-compliance enterprise AuthN (audit §1 / §5)  
**lean-grpc pin today:** `https://github.com/RileyBetts/lean-grpc.git` @ `v1.0.0` (`rev` `33334dec…` in `lean/lake-manifest.json`)

## 1. Why this exists

lean-compliance’s production entrypoint is a Lean gRPC server (`lean_compliance_server`) built on lean-grpc. Enterprise AuthN requires:

1. TLS (and mTLS) on the listen path — **partially available today** via `Grpc.Server.serveTls` + `Tls.Config.clientCaPath`.
2. A **verified caller identity** derived from the peer certificate, passed into application handlers — **not available today**.

Without (2), mTLS only proves “some cert signed by our CA connected.” It does **not** let lean-compliance map that connection to `oms-desk-a` vs `admin`. Application code would still trust a self-declared `principalId` on the wire — the Critical gap in [`enterprise_readiness_audit.md`](enterprise_readiness_audit.md) §1.

This document specifies what lean-grpc must expose so lean-compliance can stop trusting client-supplied principals outside development.

## 2. Current lean-grpc surface (verified against vendored tree)

| Capability | Status | Evidence |
|---|---|---|
| Plaintext h2c serve | Present | `Grpc.Server.serveH2c` |
| TLS serve (server cert/key) | Present | `Grpc.Server.serveTls`, `Tls.Config.certPath` / `keyPath` |
| mTLS verify client cert | Present | `Tls.Config.clientCaPath` → native `SSL_VERIFY_PEER \| SSL_VERIFY_FAIL_IF_NO_PEER_CERT` |
| Client mTLS dial | Present | `Tls.Config` client `certPath`/`keyPath`; cookbook mTLS section |
| Loopback TLS/mTLS tests | Present | `Tests/TlsServer.lean`, `Tests/TlsLoopback.lean` (per docs) |
| Peer certificate subject/SAN exposed to Lean | **Missing** | No `SSL_get_peer_certificate` / X509 subject API in `native/tls_ffi.c` or `Grpc.Native.Tls` |
| Request context on unary handlers | **Missing** | `UnaryHandler := ByteArray → IO (ByteArray × Status)` — body only; no metadata, no peer identity |
| Server interceptor access to peer identity | **Missing** | `Grpc.Interceptor.ServerUnary` wraps the same body-only handler |
| Inbound `authorization` metadata to handler | **Missing / incomplete** | Client can *send* bearer metadata; server handler does not receive a typed request context with headers |

## 3. Goals (must)

### G1 — Peer identity after mTLS

After a successful mTLS handshake (`clientCaPath` set and client cert verified), lean-grpc must make the verified client identity available to Lean application code for that RPC.

**Minimum identity fields:**

| Field | Required | Notes |
|---|---|---|
| `subject_dn` | Must | Full subject DN string (OpenSSL one-line or RFC 2253 — pick one and document) |
| `common_name` | Must | CN if present; else empty |
| `dns_sans` | Must | Zero or more DNS SANs |
| `uri_sans` | Must | Zero or more URI SANs (SPIFFE IDs matter for service accounts) |
| `fingerprint_sha256` | Should | Hex SHA-256 of DER cert; useful for pin/allowlist debugging |
| `serial` | Nice | Hex serial |

Identity must come **only** from the verified peer cert on the TLS connection — never from client-supplied gRPC metadata that claims to be the subject.

### G2 — Request context on server handlers

Replace (or overload) body-only unary registration with a context-aware API, e.g.:

```lean
structure ServerCallContext where
  peerIdentity : Option PeerIdentity   -- none on h2c / TLS without client cert
  metadata     : Metadata              -- inbound headers (lowercased keys)
  methodPath   : String                -- e.g. /lean_compliance.v1.ComplianceGate/AssessOrder
  -- optional later: remoteAddr, deadline remaining, compression

abbrev UnaryHandlerWithContext :=
  ServerCallContext → ByteArray → IO (ByteArray × Status)
```

Requirements:

- Existing `UnaryHandler` / `register` may remain for back-compat, but new `registerWithContext` (name flexible) must be first-class and used by health/reflection without breaking them.
- Streaming handlers (server/client/bidi) need the same context availability in a follow-on if not in v1 of this work — document if deferred.
- `peerIdentity = none` when: plaintext h2c; TLS without `clientCaPath`; or client presented no cert (should not happen if mTLS required — fail handshake instead).

### G3 — Fail closed on mTLS misconfiguration

When `clientCaPath` is set:

- Handshake **must** fail if client omits cert or cert fails verify (already intended).
- Application must be able to distinguish “authenticated peer” (`some identity`) from “should be impossible” and treat missing identity under mTLS as `UNAUTHENTICATED` / internal miswire — not as anonymous success.

### G4 — Tests lean-compliance will rely on

Upstream CI (or published test binary patterns) must cover:

1. TLS without client cert + `clientCaPath` set → connection rejected.
2. mTLS with valid client cert → handler observes `peerIdentity.common_name` / SAN matching fixture cert.
3. Two different client certs → two different `peerIdentity` values in handler.
4. h2c path → `peerIdentity = none`.
5. Attacker-controlled metadata header `x-client-subject: admin` does **not** appear in `peerIdentity` (only in raw `metadata` if sent — app must ignore it for AuthN).

## 4. Non-goals (out of scope for this handoff)

- lean-compliance RBAC policy evaluation (roles, fund/account scopes) — stays in lean-compliance.
- Full SPIFFE/SPIRE workload API integration (URI SAN extraction is enough for apps to map SPIFFE IDs).
- JWT/OIDC token validation inside lean-grpc (optional future; not blocking lean-compliance mTLS AuthN).
- Changing ALPN/`h2` behavior unrelated to identity.
- Fixing all items in lean-grpc `docs/security-review-2026-08.md` — only IAM-relevant items below are in scope for this ask.

## 5. Suggested API shape (informative, not mandatory)

Lean-compliance can adapt to equivalent designs; this is a concrete target to reduce bikeshedding.

### Native FFI (`tls_ffi.c` / `Grpc.Native.Tls`)

```c
/* After accept + handshake; returns 1 if peer cert present and verified path used. */
int lean_grpc_tls_peer_identity(
  lean_grpc_ssl_conn *c,
  char *subject_dn, size_t subject_dn_len,
  char *cn, size_t cn_len,
  /* SAN lists: NUL-separated or JSON blob — document encoding */
  char *dns_sans, size_t dns_sans_len,
  char *uri_sans, size_t uri_sans_len,
  char *fp_sha256_hex, size_t fp_len
);
```

Or return a Lean object built in FFI. Prefer not requiring apps to parse ASN.1 in Lean.

### Lean transport plumbing

Today `Tls.serveH2` accepts a connection and calls `H2.serveTransport (Grpc.Native.Tls.transport conn) handler` with an `H2.StreamHandler` that does **not** receive `conn`. Identity must be:

- attached to the transport / connection object, and
- threaded into `Grpc.Server.handlerFor` so unary dispatch can build `ServerCallContext`.

This is the core engineering change: **connection-scoped state → per-RPC context**.

### Example app usage (lean-compliance intent)

```lean
s := Grpc.Server.registerWithContext s "lean_compliance.v1.ComplianceGate" "AssessOrder" fun ctx req => do
  match ctx.peerIdentity with
  | none => pure (errBody, .unauthenticated "mtls_required")
  | some id =>
      -- map id.uri_sans / id.common_name → principal_id via local policy
      handleAssess (principalFrom id) req
```

## 6. Compatibility & versioning

- Prefer additive APIs (`registerWithContext`) so existing examples keep compiling.
- If `UnaryHandler` signature must change, ship a **minor/major bump** lean-compliance can pin (`v1.1.0` or `v2.0.0`) and document migration in lean-grpc CHANGELOG.
- lean-compliance currently requires `@ "v1.0.0"` — will bump pin once the IAM release tags.

## 7. Documentation lean-grpc should ship with the feature

1. Cookbook update: “mTLS → read `ctx.peerIdentity` in handler” (extend `docs/cookbook-interceptors.md`).
2. Explicit warning: **do not** treat inbound metadata `x-forwarded-client-cert` / custom subject headers as AuthN unless the operator runs a **trusted TLS-terminating proxy** and lean-grpc documents a separate “trusted proxy identity” mode (optional; not required for lean-compliance in-process mTLS path).
3. Security notes: identity fields are only as trustworthy as the `clientCaPath` PKI; document private CA operational expectations briefly.

## 8. Acceptance criteria (Definition of Done for lean-grpc)

- [x] Native API extracts subject DN, CN, DNS SANs, URI SANs from verified peer cert.
- [x] Server unary handler (context API) can read `peerIdentity` for mTLS connections.
- [x] Automated test proves two client certs yield two identities inside the handler.
- [x] Automated test proves metadata cannot forge `peerIdentity`.
- [x] Cookbook + API reference updated.
- [ ] Tagged release lean-compliance can depend on. *(in-tree **1.1.0**; maintainer tags `v1.1.0` manually)*

## 9. Priority / sequencing relative to lean-compliance

| lean-compliance phase | lean-grpc dependency |
|---|---|
| Phase 2a — wire `serveTls` + env cert paths | **None** — use existing `serveTls` / `clientCaPath` |
| Phase 2b — stop trusting wire `principalId` | **Blocked on G1+G2** (this document) |
| Interim workaround | TLS-terminating sidecar injects identity metadata — **not preferred**; only if lean-grpc IAM slips; requires trusted-network assumptions documented in ops |

**Ask:** Please treat G1+G2 as P0 for any consumer needing enterprise IAM on Lean gRPC servers. Phase 2a in lean-compliance can proceed in parallel; Phase 2b merges after the lean-grpc tag exists (or after a temporary sidecar stopgap explicitly labeled interim).

## 10. Related lean-grpc security-review items (optional stretch)

From vendored `docs/security-review-2026-08.md`, these amplify IAM trust if fixed in the same release train — not hard blockers for the identity API itself:

- Hostname verify gaps on sensitive TLS dial paths.
- Documented insecure escapes (`insecureSkipVerify`, h2c fallbacks) remaining easy to leave on in production.

lean-compliance will refuse insecure listen modes outside development on its side; library-level hard refusals would still help all consumers.

## 10. Contact / consumer expectations

When the feature lands, lean-compliance will:

1. Bump `require «lean-grpc»` to the new tag.
2. Map `uri_sans` / `common_name` → `principal_id` via `config/rbac.yaml` (`cert_subjects` / `spiffe_ids`).
3. Ignore request-body `principalId` whenever `LEAN_COMPLIANCE_ENV` ∈ {staging, production}.
4. Add interop tests: Python/grpcio mTLS client ↔ Lean server identity binding.

**Also file upstream:** failed TLS handshake / plaintext TCP connect against an mTLS listener currently aborts the accept loop (`uncaught exception: tls accept: SSL_accept failed`). Accept errors should be logged and the loop continued — otherwise readiness probes and misbehaving clients take down the server.

**Also file upstream:** failed TLS handshake / plaintext TCP connect against an mTLS listener currently aborts the accept loop (`uncaught exception: tls accept: SSL_accept failed`). Accept errors should be logged and the loop continued — otherwise readiness probes and misbehaving clients take down the server.

Questions for lean-grpc maintainers can be filed against this file’s §3–§8 checklist.
