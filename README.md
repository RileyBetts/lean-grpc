# lean-grpc

General-purpose **Lean 4 gRPC library**: HPACK + HTTP/2 + gRPC framing on `Std.Async.TCP`.

Standalone Lake package (**0.5.0**). Consumers depend via git tag or, after indexing, [Reservoir](https://reservoir.lean-lang.org/).

**Public libraries:** `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (umbrella `LeanGrpc`). Tests and examples are not API.

## Install / depend

**System deps:** OpenSSL + zlib (Debian/Ubuntu: `libssl-dev pkg-config zlib1g-dev`; macOS Homebrew: `openssl` / `openssl@3` + `pkg-config`). If headers are missing: `./scripts/fetch-openssl-headers.sh`. On macOS, set `LIBRARY_PATH` so the linker finds SDK `libz` and Homebrew OpenSSL (see [docs/packaging.md](docs/packaging.md)).

In your `lakefile.lean`:

```lean
require «lean-grpc» from git
  "https://github.com/RileyBetts/lean-grpc.git" @ "v0.5.0"
```

Then `import Grpc`. After Reservoir lists the package you can use `require «lean-grpc»` without a git URL. Packaging details and the maintainer release checklist: [docs/packaging.md](docs/packaging.md).

## Documentation

| Doc | Description |
|---|---|
| [docs/README.md](docs/README.md) | Documentation index |
| [Getting started](docs/getting-started.md) | Typed unary helloworld, TLS, Lake dependency |
| [Cookbooks](docs/cookbook-unary.md) | Unary · [streaming](docs/cookbook-streaming.md) · [interceptors / mTLS](docs/cookbook-interceptors.md) |
| [Packaging](docs/packaging.md) | Lake/Reservoir layout, consumer contract, release checklist |
| [Architecture](docs/architecture.md) | Layering and data flow |
| [API reference](docs/api-reference.md) | Module catalogue |
| [Protocol mapping](docs/protocol-mapping.md) | gRPC-over-HTTP/2 mapping for this stack |
| [Conformance](docs/conformance.md) | Scorecard, interop matrix, allowlists |
| [TLS / Envoy](docs/tls-envoy.md) | In-process OpenSSL and sidecars |
| [CHANGELOG](CHANGELOG.md) | Version history |
| [CONTRIBUTING](CONTRIBUTING.md) | Dev setup and PR expectations |
| [SECURITY](SECURITY.md) | Vulnerability reporting |

## Status

Near **grpc-go / official interop** parity for general-purpose use. Core wire + Go/Python/Rust interop and stress/framing gates are CI-gated. Cloud-edge items (live Google ADC, ALTS) remain mock/allowlisted.

Rough estimates (see [conformance.md](docs/conformance.md) for detail):

| Axis | Implemented | Tested |
|---|---:|---:|
| Official gRPC standard | ~95% | ~90% |
| vs grpc-go surface | ~93% | ~88% |
| vs Python (grpcio) peer | ~92% | ~82% |
| vs Rust (tonic) peer | ~92% | ~82% |

| Layer | Package | Notes |
|---|---|---|
| Bytes / slices | `Bytes` | Hot-path slice views, BE helpers, buffer pool |
| HPACK | `Hpack` | Static + dynamic table, Huffman encode/decode |
| HTTP/2 h2c | `H2` | Full h2spec hard gate; flow control; CONTINUATION; §8.1 |
| Protobuf (minimal) | `Proto` | Enums, nested, repeated, Any/map/oneof helpers |
| gRPC | `Grpc` | Duplex streams, deadlines, compression, dial/LB/retry, health/reflection/channelz |
| TLS | `Grpc.Native.Tls` + `Grpc.Tls` | **In-process** OpenSSL ALPN `h2` (sidecar optional); mTLS |
| ADC / xDS | `Grpc.Adc`, `Grpc.XdsAds` | SA/metadata Bearer; ADS LDS→EDS chain |
| Codegen | `protoc-gen-lean4-grpc` | Text path + real `CodeGeneratorRequest` path |

**Allowlist:** ALTS / GCE channel credentials (see `Grpc.Gcp`).

## Build

```bash
./scripts/fetch-openssl-headers.sh   # if libssl-dev is unavailable
lake build
lake build bytesTests hpackTests h2Tests grpcTests trailersLoopback
./.lake/build/bin/grpcTests
./scripts/build_native.sh            # optional zlib_helper for peer gzip (+ tls_proxy)
```

## Quick start

```bash
./scripts/gen-helloworld.sh   # typed stubs → Examples/Helloworld/Generated.lean
lake build helloworldServer helloworldClient
./.lake/build/bin/helloworldServer &
./.lake/build/bin/helloworldClient 127.0.0.1 50051 World
```

Full walkthrough: [docs/getting-started.md](docs/getting-started.md). Cookbooks: [unary](docs/cookbook-unary.md), [streaming](docs/cookbook-streaming.md), [interceptors / mTLS](docs/cookbook-interceptors.md).

## Interop

```bash
./scripts/run-go-to-lean.sh                 # Go client → Lean server
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/run-python-to-lean.sh             # Python client → Lean
GRPC_PORT=10001 ./scripts/interop-lean-python.sh
./scripts/run-rust-to-lean.sh               # Rust (tonic) client → Lean
GRPC_PORT=10001 ./scripts/interop-lean-rust.sh
./scripts/interop-compress-go-lean.sh       # gzip both directions (Go gzip server)
./scripts/interop-tls-go-lean.sh            # in-process TLS Lean → Go
./scripts/run-adc-smoke.sh                  # ADC against local mock
./scripts/run-xds-ads-smoke.sh              # Fake ADS chain → unary
./scripts/run-codegen-fixture.sh
./scripts/run-soak.sh
./scripts/h2spec.sh
```

## Helloworld / RouteGuide / soak

```bash
lake build helloworldServer helloworldClient benchSoak
./.lake/build/bin/helloworldServer &
./.lake/build/bin/helloworldClient 127.0.0.1 50051 World
./.lake/build/bin/benchSoak 127.0.0.1 50051 30
```

## License

SPDX **Apache-2.0** — see [LICENSE](LICENSE) (full terms) and [NOTICE](NOTICE) (copyright).
