# Conformance & interop

## Status (~80% implemented / ~75% tested for h2c)

Target use: general-purpose **h2c** gRPC behind Envoy/Caddy for Anchor. Native Lean TLS and full official-auth interop remain deferred.

| Area | Result |
|---|---|
| Unit: `bytesTests`, `hpackTests`, `h2Tests`, `grpcTests` | Pass (Huffman, trailers, timeout parse, metadata `-bin`, stored + peer gzip) |
| `trailersLoopback` | Pass |
| Helloworld h2c | Pass |
| Lean↔Lean interop unary + streaming | Pass (`empty_unary` … `empty_stream`) |
| Go↔Lean unary + streaming | Pass (hard CI) |
| Go→Lean unary **gzip** | Pass (`scripts/gzip-go-lean.sh`, hard CI) |
| RouteGuide (public stream registration APIs) | Pass |
| Codegen unary + streaming stubs | Pass |
| h2spec **core** (`3.5`, `4.1`, `6.5`, `6.7`, `6.8`) | Pass (hard CI); full suite soft artifact |
| Bench lean↔lean unary (n=200) | avg≈87ms p50≈87ms p99≈99ms (local) |
| Native TLS / ALPN `h2` | Deferred (sidecar) |
| Full official auth matrix | Deferred |

CI: `.github/workflows/ci.yml` — unit + Lean interop + Go interop (incl. streaming + gzip) + h2spec core hard gate.

## Features (implemented)

- **HTTP/2 h2c:** preface, SETTINGS/PING/WINDOW_UPDATE/HEADERS/DATA/RST/GOAWAY, trailers, pad/priority strip, concurrent accept, max concurrent streams refuse, send-side flow control (`queueSend` / SETTINGS window deltas), GOAWAY drain helper
- **HPACK:** static + dynamic table, Huffman encode/decode
- **gRPC:** unary + `StreamReader`/`StreamWriter`, Channel (reuse, idle keepalive PING, deadline check, `goAway`), metadata (+ `-bin`), percent-encoded `grpc-message`, `grpc-timeout`, max message size, identity + **peer gzip** (`gzip` binary inflate/deflate; stored fallback)
- **Streaming:** public `Grpc.Server` registration (`register` / `registerServerStream` / `registerClientStream` / `registerBidi`); RouteGuide showcase
- **Proto:** wire codec with enums, nested, repeated (packed + unpacked); helloworld + interop + RouteGuide messages
- **Codegen:** `protoc-gen-lean4-grpc` emits unary + streaming client stubs and streaming register helpers
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
         cancel_after_begin server_streaming client_streaming ping_pong empty_stream; do
  ./.lake/build/bin/interopClient 127.0.0.1 10000 "$c"
done
kill $pid
```

## Official Go gRPC interop

```bash
go install google.golang.org/grpc/interop/client@latest
go install google.golang.org/grpc/interop/server@latest
./scripts/run-go-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
```

Cases: unary + cancel + `server_streaming`, `client_streaming`, `ping_pong`, `empty_stream`.

Gzip peer:

```bash
./scripts/gzip-go-lean.sh
```

## h2spec

```bash
./scripts/h2spec.sh
```

**Hard gate** sections: `http2/3.5`, `http2/4.1`, `http2/6.5`, `http2/6.7`, `http2/6.8`.
Full suite is still logged softly to `/tmp/lean-grpc-h2spec.txt`.

## Benchmarks

```bash
lake build helloworldServer benchUnary
./.lake/build/bin/helloworldServer &
./.lake/build/bin/benchUnary 127.0.0.1 50051 200
```

| Peer | n | avg_ms | p50_ms | p99_ms |
|---|---|---|---|---|
| lean↔lean unary | 200 | ~87 | ~87 | ~99 |
| tonic peer | — | _(not recorded)_ | — | — |

Numbers are wall-clock ms on a local developer host (not a dedicated bench machine).

## RouteGuide demo

```bash
lake build routeGuideServer routeGuideClient
./.lake/build/bin/routeGuideServer &
./.lake/build/bin/routeGuideClient 127.0.0.1 50052
```

## Anchor-ready gate

Unary + streaming h2c behind a TLS sidecar is the intended Anchor bar: trailers, flow control, Lean↔Go interop (incl. gzip unary), h2spec core, documented limits (no native TLS, no OAuth/ALTS).
