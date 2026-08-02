# Changelog

All notable changes to lean-grpc are documented here. The package version is the Lake/`Grpc.version` semver (currently **0.5.0**). Git tags such as `v0.5.0` are created manually by maintainers when publishing.

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
