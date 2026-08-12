# Changelog

All notable changes to lean-grpc are documented here. The package version is the Lake/`Grpc.version` semver (currently **1.5.0**). Git tags such as `v1.5.0` are created manually by maintainers when publishing.

## [1.5.0] — 2026-08-12

Three sequenced engineering tranches: ConnState proof foundations (v1.4.0), security hardening LGSEC-2026-23 + LGSEC-2026-32 (v1.4.1), and streaming `ServerCallContext` for mTLS IAM parity (v1.5.0).

### Tranche 1 — `H2.ConnState` proof foundations (was v1.4.0)

New `Proofs/ConnState.lean` — zero `sorry`, CI-gated:

- **CONTINUATION sequencing:** `handleFrame` rejects any non-CONTINUATION frame while `expectContinuation` is set; CONTINUATION for the wrong stream id is also a connection error.
- **Non-negative recv windows:** `recvConnWindow` and per-stream `recvWindow` remain ≥ 0 after DATA within budget; DATA exceeding window triggers FLOW_CONTROL GOAWAY.
- **`ENHANCE_YOUR_CALM`:** server rejects a header block exceeding `SETTINGS_MAX_HEADER_LIST_SIZE` with GOAWAY error code 0xb.
- **GOAWAY gate:** `handleFrame` rejects new streams (id > `lastPeerStreamId`) and re-seen idle streams once `wentAway = true`; receiving a GOAWAY frame sets `wentAway`.

### Tranche 2 — Security hardening (was v1.4.1)

**LGSEC-2026-23 — Huffman decode-trie rewrite (`Hpack/Huffman.lean`):**
- Replaced `O(n)` linear scan of `fullTable` per accumulated prefix with a pre-built `TrieRow` array sorted by code-length, enabling O(257) = O(1) per-symbol decode bounded by the fixed table size.
- Fixed bit-accumulator mask bug (stale high bits above bit 29 now cleared with `&&& 0x3fffffff` after each consume).
- Added `Hpack.Huffman.Error` `BEq`/`DecidableEq` instances.
- New lemmas in `Proofs/Hpack.lean`: EOS symbol rejection, zero-padding rejection, valid-padding acceptance, and encode→decode roundtrip for "application/grpc".

**LGSEC-2026-32 — xDS bootstrap JSON state-machine (`Grpc/Xds.lean`):**
- Replaced the hand-rolled string scraper (`parseServerUris`, `parseBootstrap`) with a proper recursive-descent JSON parser: `parseVal` / inline array+object parsing consuming `fuel : Nat` for structural recursion.
- Handles arbitrary whitespace, field reordering, `\"` escapes, nested objects, and unterminated-value attacks (returns `none` safely).
- `parseEndpointsJson` also updated to use the new parser.

### Tranche 3 — Streaming `ServerCallContext` (IAM parity, v1.5.0)

**API additions (all additive):**
- `Grpc.StreamCallContext` — alias for `ServerCallContext`; available in all streaming handler types.
- `Stream.ServerStreamHandlerWithContext`, `Stream.ClientStreamHandlerWithContext`, `Stream.BidiStreamHandlerWithContext` — handler types carrying `StreamCallContext`.
- `MethodHandler.serverStreamCtx`, `.clientStreamCtx`, `.bidiCtx` — new dispatch variants.
- `Server.registerServerStreamWithContext`, `registerClientStreamWithContext`, `registerBidiWithContext` — streaming registration with context.
- `Server.registerServerStreamTypedWithContext`, `registerClientStreamTypedWithContext`, `registerBidiTypedWithContext` — typed+decoded variants.
- **Codegen:** `protoc-gen-lean4-grpc` now emits `register{Svc}{Method}ServerStreamWithContext`, `…ClientStreamWithContext`, `…BidiWithContext` alongside existing body-only registrars.

Migration: fully additive — bump pin to `v1.5.0`. All existing `register*` APIs and handler types are unchanged; the `WithContext` variants are opt-in.

## [1.3.0] — 2026-08-11

Off-loop TLS so OpenSSL does not stall the UV loop ([#10](https://github.com/RileyBetts/lean-grpc/issues/10)).

- **`H2.runOffLoop` / `AsyncByteTransport.ofBlockingOffLoop`:** blocking `IO` (including `SSL_*`) runs on `IO.asTask .dedicated`, then resumes Async — UV stays free.
- **Async TLS APIs:** `Tls.connectH2Async`, `Tls.serveH2Async`, `Server.serveTlsAsync`. Sync `connectH2` / `serveH2` / `serveTls` remain pure blocking `IO` (safe under `IO.asTask`; no nested `Async.block`).
- **Honesty:** still **blocking** OpenSSL FFI — documented as off-loop, not nonblocking BIO.
- **Tests:** `asyncTlsLoopback` — concurrent off-loop TLS clients + Async h2c on one UV loop; in-process `serveTlsAsync` smoke.
- **Docs:** [docs/async-io.md](docs/async-io.md) updated for the v1.3.0 TLS model.

Migration: additive — bump pin to `v1.3.0`. Prefer `*Async` TLS under Async composition; keep IO APIs for lean-compliance.

## [1.2.0] — 2026-08-11

Honest Async IO + native Async h2c path ([#6](https://github.com/RileyBetts/lean-grpc/issues/6)).

- **Docs honesty:** README / architecture / package description no longer imply end-to-end Async for the blocking IO adapters. New [docs/async-io.md](docs/async-io.md) describes UV-loop ownership, sync adapters, and the TLS sync caveat.
- **Async transport:** `H2.AsyncByteTransport`, `tcpTransportAsync` (send/recv **without** `.block`); `ByteTransport` / `tcpTransport` kept as `.block` adapters.
- **Async h2c:** `listenH2cAsync` / `connectH2cAsync` / `awaitResponseAsync` / `serveH2cAsync` / `Channel.unaryAsync` / `Client.unaryCallAsync` — zero `.block` on accept/connect/send/recv for the Async call chain.
- **Compatibility:** existing `serveH2c`, `unary`, `connectH2c` remain; they `.block` the Async core at the edge.
- **TLS:** in-process OpenSSL FFI stays **blocking** in v1.2.0 (documented); no false “fully async TLS” claim.
- **Tests:** `asyncH2cLoopback` — concurrent Async clients against `serveH2cAsync` on one UV loop.
- **Example:** helloworld server honors `LEAN_GRPC_ASYNC=1` → `serveH2cAsync`.

Migration: additive — bump pin to `v1.2.0`. Prefer `*Async` for new h2c composition; keep IO APIs for lean-compliance and existing code.

## [1.1.0] — 2026-08-04

Additive IAM surface for enterprise mTLS AuthN (lean-compliance G1–G4).

- **Peer identity:** `Grpc.Native.Tls.peerIdentity?` extracts verified client cert fields (RFC 2253 subject DN, CN, DNS/URI SANs, SHA-256 fingerprint, serial) via OpenSSL after mTLS handshake.
- **Request context:** `ServerCallContext` + `registerWithContext` / `registerTypedWithContext` pass `peerIdentity`, inbound metadata, and `methodPath` into unary handlers. Legacy `register` remains (ignores context).
- **TLS serve:** `Tls.serveH2` takes a per-connection handler factory; failed accepts/handshakes are logged and the listen loop continues.
- **Interceptors:** `registerUnaryWithContext`, `requirePeerIdentity` (fail closed when `mtlsRequired` and identity missing).
- **Tests:** `tlsLoopback` covers dual-cert identity binding, metadata non-forgery, h2c → `none`, accept-loop survival.
- **Codegen:** `protoc-gen-lean4-grpc` emits `register{Svc}{Method}WithContext` alongside body-only registrars.
- **Examples:** MirrorForge `Stamp` uses `registerUnaryWithContext` (Bearer metadata + body-token fallback; optional env-gated TLS/mTLS).
- **Docs:** cookbook mTLS → `ctx.peerIdentity`; API reference; security PKI note.
- **Deferred:** streaming handlers with context; trusted-proxy identity mode; JWT/OIDC validation inside lean-grpc.

Migration: additive API — bump consumer pin from `v1.0.0` to `v1.1.0`. Prefer `registerWithContext` for AuthN; do not trust client-supplied subject metadata.

## [1.0.0] — 2026-08-02

First production-oriented packaging release of the independent Lean 4 gRPC stack. **Scope note:** selected pure-codec proofs ship in CI; `H2.ConnState`, Huffman trie rewrite, and broader ∀ roundtrips remain follow-ups — see [ROADMAP.md](ROADMAP.md) and [docs/proofs.md](docs/proofs.md).

- Compile-time **`Proofs`** Lake library for high-leverage pure codecs (status maps, BE ints, gRPC identity framing lemmas, protobuf varint fixtures, HTTP/2 frame-type maps + fixtures, HPACK integer/header fixtures, metadata percent/base64/timeout). Run `lake build Proofs`; documented in [docs/proofs.md](docs/proofs.md). Hard-gated in CI.
- Provenance / IP diligence note ([docs/provenance.md](docs/provenance.md)): independent PROTOCOL-HTTP2 implementation; `NOTICE` attributes Apache-2.0 gRPC-authors interop protos under `python_interop/proto/` and `rust_interop/proto/`.
- Near grpc-go / official interop parity for general-purpose use (Go/Python/Rust peers, h2spec, stress demos) — see [docs/conformance.md](docs/conformance.md)

### Known allowlists

- ALTS / GCE channel credentials (`Grpc.Gcp`)
- Live Google ADC remains mock/allowlisted in regular CI

## [0.5.0] — 2026-08-01

Initial public packaging baseline for Lake / Reservoir distribution.

- Pure Lean 4 gRPC stack on `Std.Async`: `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc`
- Near grpc-go / official interop parity for general-purpose use (see [docs/conformance.md](docs/conformance.md))
- In-process OpenSSL TLS (ALPN `h2`) and zlib bridges; optional sidecar TLS
- Dial / LB / retry, health, reflection, channelz, ADC (mock CI), xDS ADS subset
- `protoc-gen-lean4-grpc` codegen (text path + `CodeGeneratorRequest`)
- CI hard gates: unit tests, Lean↔Lean interop, Go/Python interop, h2spec, stress demos
- Packaging docs: [docs/packaging.md](docs/packaging.md)

### Known allowlists

- ALTS / GCE channel credentials (`Grpc.Gcp`)
- Live Google ADC remains mock/allowlisted in regular CI
