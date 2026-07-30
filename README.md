# lean-grpc

General-purpose **pure Lean 4 gRPC library**: HPACK + HTTP/2 + gRPC framing on `Std.Async.TCP`.

Standalone project (not part of Anchor Chain). Consumers such as Anchor can depend on it via Lake.

**Libraries:** `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (plus examples/tests).

## Status (~80% / ~75% tested for h2c)

| Layer | Package | Notes |
|---|---|---|
| Bytes / slices | `Bytes` | Hot-path slice views, BE helpers, buffer pool |
| HPACK | `Hpack` | Static + dynamic table, Huffman encode/decode |
| HTTP/2 h2c | `H2` | Frames, settings, send-side flow control, trailers, concurrent accept, GOAWAY |
| Protobuf (minimal) | `Proto` | Enums, nested, repeated/packed; helloworld/interop/route_guide |
| gRPC | `Grpc` | Unary + StreamReader/Writer, Channel keepalive/deadlines, metadata, **peer gzip**, TLS stub |
| Codegen | `protoc-gen-lean4-grpc` | Unary + streaming client stubs and register helpers |

**Tested:** unit tests, trailers loopback, helloworld, Lean↔Lean + Lean↔Go unary/streaming, Go gzip unary, RouteGuide, h2spec **core** hard gate, recorded lean↔lean unary bench. See [docs/conformance.md](docs/conformance.md).

TLS: use an external terminator (see [docs/tls-envoy.md](docs/tls-envoy.md)). `Grpc.Tls` is a reserved API.

**Deferred:** native Lean TLS + ALPN `h2`; full official interop auth (OAuth/JWT/ALTS).

**Protobuf:** [Lean-zh/protobuf](https://github.com/Lean-zh/protobuf) is preferred when it tracks Lean 4.32.1; until then we ship a minimal codec.

## Build

```bash
lake build
lake build bytesTests hpackTests h2Tests grpcTests trailersLoopback
./.lake/build/bin/bytesTests
./.lake/build/bin/hpackTests
./.lake/build/bin/h2Tests
./.lake/build/bin/grpcTests
./.lake/build/bin/trailersLoopback
```

## Helloworld (h2c)

```bash
lake build helloworldServer helloworldClient
./.lake/build/bin/helloworldServer &
./.lake/build/bin/helloworldClient 127.0.0.1 50051 World
```

## Interop

```bash
./scripts/interop-lean-go.sh          # Go client → Lean server
GRPC_PORT=10001 ./scripts/interop-go-lean.sh  # Lean client → Go server
./scripts/gzip-go-lean.sh             # Go gzip compressor → Lean
./scripts/h2spec.sh                   # h2spec core (hard) + full soft log
```

## RouteGuide

```bash
lake build routeGuideServer routeGuideClient
./.lake/build/bin/routeGuideServer &
./.lake/build/bin/routeGuideClient 127.0.0.1 50052
```

## Codegen

```bash
lake build protocGenLean4Grpc
LEAN_GRPC_OUT=./examples/generated ./.lake/build/bin/protoc-gen-lean4-grpc examples/helloworld.proto
LEAN_GRPC_OUT=./examples/generated ./.lake/build/bin/protoc-gen-lean4-grpc examples/route_guide.proto
```

## License

Apache-2.0
