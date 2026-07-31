# lean-grpc

General-purpose **pure Lean 4 gRPC library**: HPACK + HTTP/2 + gRPC framing on `Std.Async.TCP`.

Standalone project. Consumers depend on it via Lake.

**Libraries:** `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (plus examples/tests).

## Status (~100% / ~99.5% toward grpc-go parity)

| Layer | Package | Notes |
|---|---|---|
| Bytes / slices | `Bytes` | Hot-path slice views, BE helpers, buffer pool |
| HPACK | `Hpack` | Static + dynamic table, Huffman encode/decode |
| HTTP/2 h2c | `H2` | Full h2spec hard gate; flow control; CONTINUATION; §8.1 |
| Protobuf (minimal) | `Proto` | Enums, nested, repeated, Any/map/oneof helpers |
| gRPC | `Grpc` | Duplex streams, deadlines, gzip, dial/LB/retry, health/reflection/channelz |
| TLS | `Grpc.Native.Tls` + `Grpc.Tls` | **In-process** OpenSSL ALPN `h2` (sidecar optional) |
| ADC / xDS | `Grpc.Adc`, `Grpc.XdsAds` | SA/metadata Bearer; ADS CDS/EDS subset |
| Codegen | `protoc-gen-lean4-grpc` | Typed abbrevs + unary/streaming stubs |

See [docs/conformance.md](docs/conformance.md) for the phase scorecard and interop checklist.

**Allowlist:** ALTS / GCE channel credentials (see `Grpc.Gcp`).

## Build

```bash
./scripts/fetch-openssl-headers.sh   # if libssl-dev is unavailable
lake build
lake build bytesTests hpackTests h2Tests grpcTests trailersLoopback
./.lake/build/bin/grpcTests
./scripts/build_native.sh            # zlib_helper (+ optional tls_proxy)
```

## Interop

```bash
./scripts/run-go-to-lean.sh                 # Go client → Lean server
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/run-python-to-lean.sh             # Python client → Lean
GRPC_PORT=10001 ./scripts/interop-lean-python.sh
./scripts/interop-compress-go-lean.sh       # gzip both directions (Go gzip server)
./scripts/interop-tls-go-lean.sh            # in-process TLS Lean → Go
./scripts/run-adc-smoke.sh                  # ADC against local mock
./scripts/run-xds-ads-smoke.sh              # Fake ADS (protobuf EDS) → unary
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

Apache-2.0
