# lean-grpc

General-purpose **pure Lean 4 gRPC library**: HPACK + HTTP/2 + gRPC framing on `Std.Async.TCP`.

Standalone project (not part of Anchor Chain). Once the library is well tested, consumers such as Anchor can depend on it via Lake.

**Libraries:** `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (plus examples/tests).

## Status

| Layer | Package | Notes |
|---|---|---|
| Bytes / slices | `Bytes` | Hot-path slice views, BE helpers, buffer pool |
| HPACK | `Hpack` | Static + dynamic table, Huffman encode/decode |
| HTTP/2 h2c | `H2` | Frames, settings, flow control, trailers, concurrent accept, GOAWAY helper |
| Protobuf (minimal) | `Proto` | Wire codec + helloworld/interop/route_guide messages |
| gRPC | `Grpc` | Unary + buffered/incremental streaming, channel, metadata, timeouts, gzip (stored), TLS stub |
| Codegen | `protoc-gen-lean4-grpc` | Emits Lean stubs from `.proto` services |

**Tested:** unit tests, trailers loopback, helloworld, Lean↔Lean interop (unary + streaming cases), Lean↔Go core unary/cancel cases, RouteGuide smoke. See the matrix in [docs/conformance.md](docs/conformance.md). h2spec and tonic benches are not claimed green yet.

TLS: use an external terminator (see [docs/tls-envoy.md](docs/tls-envoy.md)). `Grpc.Tls` is a reserved API.

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
