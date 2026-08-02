# Roadmap

lean-grpc **v0.5.0** (tagged on `main`) is the first public packaging baseline: an interop-tested Lean 4 gRPC stack (HTTP/2 + HPACK + protobuf framing) with CI hard gates. It is **not** a machine-checked protocol proof.

This roadmap describes the path to **v1.0.0**, centered on Lean mathematical proofs for critical wire components, plus the hardening and API stability needed to call the release “production-ready” without overstating verification claims.

Related: [CHANGELOG.md](CHANGELOG.md), [docs/conformance.md](docs/conformance.md), [docs/security-review-2026-08.md](docs/security-review-2026-08.md), [docs/packaging.md](docs/packaging.md), [SECURITY.md](SECURITY.md).

## Guiding principles

1. **Prove the pure layers first.** Codecs and connection-state transitions before IO / `Std.Async` / FFI.
2. **Never claim “proved TLS/gRPC end-to-end.”** OpenSSL and zlib remain a trusted TCB; proofs cover the Lean wire model that sits above them.
3. **Keep interop green.** Proof work must not regress h2spec, Go/Python/Rust interop, or stress/framing gates.
4. **Freeze the consumer API at v1.0.0.** Public libraries stay `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (umbrella `LeanGrpc`).

## v0.5.0 — shipped baseline

| Area | Status |
|---|---|
| Core RPC + streaming + deadlines | Interop-tested (Lean↔Lean, Go, Python, Rust) |
| HTTP/2 + HPACK | h2spec hard CI |
| TLS (in-process OpenSSL) + compression caps | Security-hardened; ASAN / `securityTests` gated |
| Dial / LB / retry, health, reflection, channelz | Present; ops demos gated |
| ADC / xDS ADS | Mock / FakeAds CI; live Google paths allowlisted |
| Formal Lean proofs | None yet |

**Explicitly out of v0.5.0:** ALTS / GCE channel credentials, HTTP CONNECT proxying, full `cacheable_unary` proxy infrastructure, formal verification.

## Toward v1.0.0

Work is grouped so each tranche can ship as a minor release (`0.6`, `0.7`, …) without waiting for the full proof stack.

### A — Proof foundations (critical path)

Machine-checked properties for the layers that define wire correctness. Prefer `theorem` / `lemma` with **zero `sorry`** in the CI-gated proof modules.

| Priority | Target | Example properties |
|---|---|---|
| P0 | `Bytes` / big-endian codecs | `decode ∘ encode = id` on well-formed inputs; truncated input ⇒ error |
| P0 | Protobuf wire (`Proto.Wire`) | Field parse roundtrip; reject illegal wire types (6/7); length-delimited bounds |
| P0 | HPACK integer coding + string literals | Integer encode/decode inverse; Huffman decode rejects padding/EOS abuse (pairs with trie rewrite) |
| P1 | HTTP/2 frames (`H2.Frame`) | Length/type/flags consistency; pad truncation ⇒ connection/stream error as specified |
| P1 | `H2.ConnState` transitions | CONTINUATION sequencing; flow-control windows never go negative after accept; oversized header list ⇒ `ENHANCE_YOUR_CALM`; GOAWAY stops new streams |
| P2 | gRPC message framing + status mapping | 5-byte prefix length; trailers-only / RST→`Status` mapping lemmas against a small abstract model |

**Non-goals for v1.0.0 proofs:** full async scheduler correctness, OpenSSL handshake, xDS control-plane completeness, Huffman *encode* optimality.

Suggested layout (to be introduced when proofs land): `Proofs/` (or per-layer `*.Proofs.lean`) with a Lake target such as `proofs` hard-gated in CI.

### B — Security & parser hardening (pairs with proofs)

Close remaining audit follow-ups so v1.0.0 is not “proved but soft”:

- Huffman **decode-trie** rewrite ([LGSEC-2026-23](docs/security-review-2026-08.md)) — mitigates CPU DoS; enables cleaner Huffman lemmas
- xDS bootstrap **JSON rewrite** ([LGSEC-2026-32](docs/security-review-2026-08.md))
- Minimal **fuzz corpora** for frames / HPACK / protobuf / zlib (`Tests/Fuzz/`) — offline or soft CI first
- `pip --require-hashes` (and keep Go/action pins current)
- Post-hardening security re-audit note in `docs/`

### C — Product / API readiness

- Document **API stability** contract for `Bytes` / `Hpack` / `H2` / `Proto` / `Grpc`
- README / SECURITY honesty: “executable + interop CI + *selected* Lean proofs; FFI trusted”
- Close or reaffirm allowlists (ALTS, live ADC, CONNECT) — do not block v1.0.0 on ALTS
- Optional: consumer smoke (`require @ "v1.0.0"` helloworld) in release checklist
- Reservoir indexing and packaging polish as needed ([docs/packaging.md](docs/packaging.md))

### D — Nice-to-have (not v1.0.0 blockers)

- Deeper grpclb / hedge race polish
- Python/Rust stress demos (parity with Go stress)
- Official `cacheable_unary` behind a real caching proxy
- Live ADC / xDS nightlies (credentials-gated)
- Broader interceptor / BinaryLog / stats surface vs grpc-go

## Milestone sketch

```text
v0.5.0 ──► v0.6.x          ──► v0.7.x              ──► v1.0.0
 shipped    Bytes+Proto       H2 ConnState +         Proof CI green,
            wire proofs +     frame lemmas +         API freeze,
            Huffman trie      fuzz seed corpora      security follow-ups
            / bootstrap JSON                         closed or documented
```

Dates are intentionally omitted; order matters more than calendar.

## What v1.0.0 will mean

| Claim | In scope for v1.0.0 |
|---|---|
| Interop-tested general-purpose gRPC over h2c/TLS | Yes (maintain v0.5.0 CI bar) |
| Selected critical codecs / H2 state properties machine-checked in Lean | Yes |
| Full PROTOCOL-HTTP2 / gRPC / TLS stack proved | **No** |
| ALTS / live Google control plane | **No** (remain allowlisted unless separately delivered) |

## How to contribute

- Proof PRs: small lemmas, no `sorry` in gated targets, preserve interop CI.
- Follow [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
- Update this roadmap when a tranche lands or a non-goal changes.
