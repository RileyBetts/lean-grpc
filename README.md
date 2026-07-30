# lean-grpc

General-purpose **pure Lean 4 gRPC library**: HPACK + HTTP/2 + gRPC framing on `Std.Async.TCP`.

Standalone project. Consumers depend on it via Lake.

**Libraries:** `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (plus examples/tests).

## Status (~100% / ~98% toward grpc-go parity)

| Layer | Package | Notes |
|---|---|---|
| Bytes / slices | `Bytes` | Hot-path slice views, BE helpers, buffer pool |
| HPACK | `Hpack` | Static + dynamic table, Huffman encode/decode |
| HTTP/2 h2c | `H2` | Full h2spec hard gate; flow control; CONTINUATION; §8.1 |
| Protobuf (minimal) | `Proto` | Enums, nested, repeated, Any/map/oneof helpers |
| gRPC | `Grpc` | Duplex streams, deadlines, gzip, dial/LB/retry, health/reflection/channelz |
| TLS | `native/tls_proxy` + `Grpc.Tls` | OpenSSL ALPN `h2` terminator in front of h2c |
| Codegen | `protoc-gen-lean4-grpc` | Typed abbrevs + unary/streaming stubs |

See [docs/conformance.md](docs/conformance.md) for the phase scorecard and interop checklist.

**Phase 10 allowlist:** GCP ADC/ALTS/ORCA/xDS (see `Grpc.Gcp`).

## Build

```bash
lake build
lake build bytesTests hpackTests h2Tests grpcTests trailersLoopback
./.lake/build/bin/grpcTests
./scripts/build_native.sh   # zlib_helper + tls_proxy
```

## Interop

```bash
./scripts/run-go-to-lean.sh                 # Go client → Lean server (non-auth matrix)
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/gzip-go-lean.sh
./scripts/interop-tls-go-lean.sh            # ALPN h2 proxy smoke
./scripts/h2spec.sh                        # full h2spec hard gate
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
