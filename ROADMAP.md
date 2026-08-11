# Roadmap

lean-grpc **v1.3.0** is the current package tip (Lake / `Grpc.version`): an interop-tested Lean 4 gRPC stack with native Async h2c APIs, **off-loop** in-process TLS (blocking OpenSSL on dedicated threads), a CI-gated **`Proofs`** library for selected pure codecs, plus additive mTLS peer-identity / request-context APIs for enterprise AuthN. It is **not** a machine-checked end-to-end PROTOCOL-HTTP2 / TLS / session proof.

This document records what shipped, what is still open, and the next proof/hardening tranches.

Related: [CHANGELOG.md](CHANGELOG.md), [docs/proofs.md](docs/proofs.md), [docs/conformance.md](docs/conformance.md), [docs/security-review-2026-08.md](docs/security-review-2026-08.md), [docs/packaging.md](docs/packaging.md), [SECURITY.md](SECURITY.md).

## Guiding principles

1. **Prove the pure layers first.** Codecs and connection-state transitions before IO / `Std.Async` / FFI.
2. **Never claim “proved TLS/gRPC end-to-end.”** OpenSSL and zlib helpers remain a trusted TCB; proofs cover the Lean wire model that sits above them.
3. **Keep interop green.** Proof work must not regress h2spec, Go/Python/Rust interop, or stress/framing gates.
4. **Keep the consumer API stable.** Public libraries stay `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (umbrella `LeanGrpc`). `Proofs` is CI/maintainer-only, not consumer API.

## Shipped — v0.5.0

First public packaging baseline (interop + Lake/Reservoir layout). Formal Lean proofs: none.

| Area | Status |
|---|---|
| Core RPC + streaming + deadlines | Interop-tested (Lean↔Lean, Go, Python, Rust) |
| HTTP/2 + HPACK | h2spec hard CI |
| TLS (in-process OpenSSL) + compression caps | Security-hardened; ASAN / `securityTests` gated |
| Dial / LB / retry, health, reflection, channelz | Present; ops demos gated |
| ADC / xDS ADS | Mock / FakeAds CI; live Google paths allowlisted |

## Shipped — v1.3.0 (TLS off-loop)

Blocking OpenSSL runs off the UV loop ([#10](https://github.com/RileyBetts/lean-grpc/issues/10), [docs/async-io.md](docs/async-io.md)).

| Included | Deferred |
|---|---|
| `runOffLoop` / `ofBlockingOffLoop` | Nonblocking BIO / `SSL_ERROR_WANT_*` + UV readiness |
| `connectH2Async` / `serveTlsAsync` | Streaming `*Async` surface beyond unary |
| `asyncTlsLoopback` CI (TLS + h2c concurrent) | Full Concurrent retry/hedge under Async TLS |

## Shipped — v1.2.0 (Async honesty)

Native Async h2c + docs that match the implementation ([#6](https://github.com/RileyBetts/lean-grpc/issues/6), [docs/async-io.md](docs/async-io.md)).

| Included | Deferred |
|---|---|
| `AsyncByteTransport` / `*Async` h2c serve/dial/unary | Streaming `*Async` beyond unary; Concurrent retry/hedge under Async |
| Sync IO APIs as `.block` adapters | Streaming `*Async` surface beyond unary |
| Concurrent `asyncH2cLoopback` CI | Full Concurrent retry/hedge under Async |

## Shipped — v1.1.0 (IAM)

Additive server AuthN plumbing for verified mTLS peer identity (see [feature/lean-grpc-iam-requirements.md](feature/lean-grpc-iam-requirements.md), [docs/cookbook-interceptors.md](docs/cookbook-interceptors.md)).

| Included | Deferred |
|---|---|
| Native peer cert extract (DN/CN/SANs/fingerprint) | Streaming handlers with `ServerCallContext` |
| `registerWithContext` / `ServerCallContext` | Trusted-proxy identity mode |
| Dual-cert + metadata non-forgery loopback tests | JWT/OIDC validation inside lean-grpc |
| Accept-loop continues after failed TLS handshake | Full SPIFFE/SPIRE workload API |

## Shipped — v1.0.0 (honest scope)

Product/packaging release with **selected** compile-time proofs. See [docs/proofs.md](docs/proofs.md).

| Included | Not included (still follow-up) |
|---|---|
| Interop bar maintained (h2spec, Go/Python/Rust, stress/framing) | Full PROTOCOL-HTTP2 / gRPC / TLS stack proved |
| `Proofs/` Lake lib + CI (`lake build Proofs`), zero `sorry` | `H2.ConnState` transition lemmas |
| ∀-style BE int / status-code / identity framing lemmas | General ∀ frame / message / varint roundtrips (many fixtures only) |
| Kernel-checked fixtures: frames, HPACK ints/headers, metadata, varints | Huffman decode padding/EOS lemmas; Huffman decode-trie rewrite |
| Provenance / NOTICE for interop protos | Fuzz seed corpora in CI |
| Allowlists reaffirmed (ALTS, live ADC, CONNECT) | Documented API stability contract (semver freeze note) |

**Explicit non-goals (unchanged):** ALTS / GCE channel credentials, HTTP CONNECT proxying, full `cacheable_unary` proxy infrastructure, end-to-end session proofs.

## Toward v1.3.x / later

Work is grouped so each tranche can ship as a minor release without waiting for a full ConnState + Huffman proof stack.

### A — Proof foundations (critical path)

Prefer `theorem` / `lemma` with **zero `sorry`** in CI-gated `Proofs/` modules.

| Priority | Target | Status / next step |
|---|---|---|
| P0 | `Bytes` / big-endian codecs | **Done** for u16/u24/u32 encode↔decode |
| P0 | Protobuf wire (`Proto.Wire`) | Partial — extend beyond varint `<128` + fixtures; field roundtrip; illegal wire types as lemmas |
| P0 | HPACK integer coding + string literals | Partial fixtures — add Huffman padding/EOS reject lemmas (pairs with trie rewrite) |
| P1 | HTTP/2 frames (`H2.Frame`) | Partial fixtures — general encode↔decode under `payload.size < 2^24`; pad truncation ⇒ connection/stream error |
| P1 | `H2.ConnState` transitions | **Open** — CONTINUATION sequencing; non-negative windows after accept; oversized header list ⇒ `ENHANCE_YOUR_CALM`; GOAWAY stops new streams |
| P2 | gRPC framing + status mapping | Partial identity framing / status maps — trailers-only / RST→`Status` against a small abstract model |

**Non-goals for the next proof tranche:** full async scheduler correctness, OpenSSL handshake, xDS control-plane completeness, Huffman *encode* optimality.

### B — Security & parser hardening (pairs with proofs)

Close remaining audit follow-ups so later minors are not “proved but soft”:

- Huffman **decode-trie** rewrite ([LGSEC-2026-23](docs/security-review-2026-08.md)) — still mitigated by header-list caps; rewrite deferred
- xDS bootstrap **JSON rewrite** ([LGSEC-2026-32](docs/security-review-2026-08.md)) — still **Open**
- Minimal **fuzz corpora** for frames / HPACK / protobuf / zlib (`Tests/Fuzz/`) — README stub only; offline or soft CI first
- Keep Go/action pins current; prefer `pip --require-hashes` where Python peers are installed
- Post-hardening security re-audit note in `docs/` when trie/bootstrap land

### C — Product / API readiness

- Document **API stability** contract for `Bytes` / `Hpack` / `H2` / `Proto` / `Grpc` (what may break in 1.x vs 2.0)
- Keep README / SECURITY honesty: “executable + interop CI + *selected* Lean proofs; FFI trusted”
- Reservoir indexing polish ([docs/packaging.md](docs/packaging.md); hosted docs at [rileybetts.ai/oss/lean-grpc](https://rileybetts.ai/oss/lean-grpc))
- Allowlists remain unless separately delivered (ALTS, live ADC, CONNECT)
- Streaming `ServerCallContext` (parity with unary IAM)

### D — Nice-to-have (not blockers)

- Deeper grpclb / hedge race polish
- Python/Rust stress demos (parity with Go stress)
- Official `cacheable_unary` behind a real caching proxy
- Live ADC / xDS nightlies (credentials-gated)
- Broader interceptor / BinaryLog / stats surface vs grpc-go

## Milestone sketch

```text
v0.5.0 ──► v1.0.0              ──► v1.1.0              ──► v1.2.0              ──► v1.3.0              ──► later 1.x
 shipped     interop +           mTLS peer identity +   Async h2c honesty     TLS off-loop (#10)    ConnState +
             selected Proofs     ServerCallContext      (#6) + sync adapters   + serveTlsAsync       general frame/msg
             (CI) + provenance   (unary IAM)                                                        roundtrips /
                                                                                                    Huffman trie
```

Dates are intentionally omitted; order matters more than calendar.

## What versions mean

| Claim | v1.0.0 | v1.1.0 | Later 1.x target |
|---|---|---|---|
| Interop-tested general-purpose gRPC over h2c/TLS | **Yes** | Maintain | Maintain |
| mTLS verified peer identity in unary handlers | **No** | **Yes** | Streaming context |
| Selected critical pure codecs machine-checked in Lean | **Yes** (partial; see [docs/proofs.md](docs/proofs.md)) | Maintain | Broaden ∀ coverage |
| `H2.ConnState` properties machine-checked | **No** | **No** | Yes (P1) |
| Full PROTOCOL-HTTP2 / gRPC / TLS stack proved | **No** | **No** | **No** (non-goal) |
| ALTS / live Google control plane | **No** (allowlisted) | **No** | Unless separately delivered |

## How to contribute

- Proof PRs: small lemmas, no `sorry` in gated targets, preserve interop CI; extend [docs/proofs.md](docs/proofs.md) when coverage grows.
- Follow [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
- Update this roadmap when a tranche lands or a non-goal changes.
