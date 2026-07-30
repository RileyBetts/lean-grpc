# Conformance & interop

## What has been tested (local)

| Area | Result |
|---|---|
| Unit: `bytesTests`, `hpackTests`, `h2Tests`, `grpcTests` | Pass (includes Huffman round-trip, gzip stored framing, trailers frames, timeout parse, metadata base64) |
| `trailersLoopback` (Lean↔Lean unary, `grpc-status` in trailers) | Pass |
| Helloworld h2c | Pass |
| Lean↔Lean interop: `empty_unary`, `large_unary`, `status_code_and_message`, `custom_metadata`, `cancel_after_begin`, `server_streaming`, `client_streaming` | Pass |
| Go client → Lean server (same five unary/cancel cases) | Pass |
| Lean client → Go server (same five unary/cancel cases) | Pass |
| RouteGuide demo (GetFeature, ListFeatures, RecordRoute, RouteChat) on `:50052` | Pass |
| Codegen smoke (`helloworld` + `route_guide` → `Generated.lean`) | Pass |
| h2spec | Soft gate only — script/CI artifact; **not** claimed green |
| Bench p50/p99 vs tonic | Harness exists; **no** recorded baseline yet |
| Native TLS / ALPN `h2` | Not implemented (sidecar only) |
| Go interop streaming cases (`server_streaming`, etc.) | Not in Go matrix; Lean↔Lean only |
| Full official interop matrix (auth, compress, etc.) | Not run |

CI workflows under `.github/workflows/ci.yml` encode the above (unit + Lean interop + Go interop + soft h2spec). Push to GitHub to confirm remote CI.

## Features (implemented)

- **HTTP/2 h2c:** preface, SETTINGS/PING/WINDOW_UPDATE/HEADERS/DATA/RST/GOAWAY, trailers, pad/priority strip, concurrent accept, max concurrent streams refuse, GOAWAY helper
- **HPACK:** static + dynamic table, Huffman encode/decode
- **gRPC:** unary client/server, Channel, metadata (+ `-bin`), percent-encoded `grpc-message`, `grpc-timeout` parse (deadline), max message size, identity + stored-gzip message flag
- **Streaming:** buffered / incremental FullDuplex-style DATA; Lean interop server/client streaming; RouteGuide
- **Proto:** minimal wire codec for helloworld + interop + RouteGuide shapes
- **Codegen:** `protoc-gen-lean4-grpc` unary stubs + streaming path constants
- **TLS:** stub API; terminate externally ([tls-envoy.md](tls-envoy.md))

## Unit tests

```bash
lake build bytesTests hpackTests h2Tests grpcTests trailersLoopback
./.lake/build/bin/bytesTests && ./.lake/build/bin/hpackTests && \
  ./.lake/build/bin/h2Tests && ./.lake/build/bin/grpcTests && \
  ./.lake/build/bin/trailersLoopback
```

## Lean↔Lean interop

```bash
lake build interopServer interopClient
./.lake/build/bin/interopServer &
pid=$!
sleep 1
for c in empty_unary large_unary status_code_and_message custom_metadata \
         cancel_after_begin server_streaming client_streaming; do
  ./.lake/build/bin/interopClient 127.0.0.1 10000 "$c"
done
kill $pid
```

## Official Go gRPC interop

Install tools:

```bash
go install google.golang.org/grpc/interop/client@latest
go install google.golang.org/grpc/interop/server@latest
```

Lean server ← Go client:

```bash
./scripts/run-go-to-lean.sh
# or: ./scripts/interop-lean-go.sh
```

Lean client → Go server:

```bash
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
```

Go cases: `empty_unary`, `large_unary`, `status_code_and_message`, `custom_metadata`, `cancel_after_begin`.

## h2spec

```bash
./scripts/h2spec.sh
```

Requires network once to fetch the `h2spec` release binary (or set `H2SPEC=/path/to/h2spec`).
Results go to `/tmp/lean-grpc-h2spec.txt`. Soft gate (exit 0) — do not treat as conformance pass until the log is green.

## Benchmarks

```bash
lake build helloworldServer benchUnary
./.lake/build/bin/helloworldServer &
./.lake/build/bin/benchUnary 127.0.0.1 50051 200
```

| Peer | n | avg_ms | p50_ms | p99_ms |
|---|---|---|---|---|
| lean↔lean unary | 200 | _(not recorded)_ | _(not recorded)_ | _(not recorded)_ |
| tonic peer | — | — | — | — |

## RouteGuide demo

```bash
lake build routeGuideServer routeGuideClient
./.lake/build/bin/routeGuideServer &
./.lake/build/bin/routeGuideClient 127.0.0.1 50052
```

## Anchor-ready gate

Unary h2c is the intended Anchor integration bar: trailers, concurrent accept, Lean↔Lean + Lean↔Go core unary cases. Streaming works for demos/interop helpers; TLS remains sidecar-only.
