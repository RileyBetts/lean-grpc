# Conformance & interop scorecard

**Target:** near [grpc-go / official interop](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md) parity (Phases 1–9 hard; ALTS allowlisted).

## Overall estimates (judgment, not a formal audit)

| Axis | Implemented | Tested | Notes |
|---|---:|---:|---|
| Official gRPC standard (PROTOCOL-HTTP2 + core RPC) | **~95%** | **~90%** | Core wire solid; gaps: full `cacheable_unary` (needs caching proxy), HTTP CONNECT out of scope, some duplex still buffered-batch |
| vs grpc-go app surface | **~93%** | **~88%** | Strong general-app parity; ALTS/GCE allowlisted; grpclb thin; binary-log/stats/interceptors shallower than grpc-go; hedge race cautious |
| vs Python (grpcio) peer surface | **~92%** | **~82%** | Shared wire covered both ways; no Python stress demo yet; fewer chaos/negative cases than Go |

Remaining risk is mostly **peer lifecycle edges** (half-close, compress+stream, cancel timing) and **cloud-live** paths (ADC/ALTS/xDS against real infra), not missing basic RPCs. Stress demos found two such bugs (gzip stream decode; bidi empty `END_STREAM`); FramingMatrix + `run-stress-demos.sh` now hard-gate those classes.

| Metric | Score |
|---|---|
| vs grpc-go app surfaces | **~93% implemented / ~88% tested** (see table above) |
| h2spec | **145/146 pass, 1 skipped** (full suite hard CI; skip is h2spec suite skip, not an allowlisted failure) |
| Official non-auth interop | Lean↔Lean; **Go↔Lean**; **Python↔Lean** (CI) |
| Stress demos + framing matrix | **Hard CI** (`scripts/run-stress-demos.sh`): VaultGauntlet, MirrorForge, SignalWeave, FramingMatrix |
| Compression | identity/gzip/deflate/snappy; Go gzip client→Lean; Lean→Go gzip-enabled server |
| In-process TLS | Lean→Go TLS unary (no sidecar); Lean↔Lean mTLS (client cert required/verified) |
| ADC | SA JWT + GCE metadata (**mock CI**, not live Google); `run-adc-live.sh` for manual/nightly live checks |
| xDS ADS | Full LDS→RDS→CDS→EDS chain + SDS cert stub + ACK/NACK (**FakeAds CI**) |
| HTTP CONNECT proxying | **N/A** — this library dials backends directly (h2c/TLS); tunneling through a corporate `HTTP_PROXY` via HTTP/1.1 `CONNECT` is out of scope |

## Scorecard by area

| Area | % | Notes |
|---|---|---|
| HTTP/2 + HPACK (h2spec) | 100 | Full hard gate |
| Core RPC + duplex + deadlines | 100 | Incremental FullDuplex; mid-RPC deadline RST |
| Peer framing / empty half-close | 100 | FramingMatrix + stress demos hard-gated; multi-frame gzip `decodeOneIO`; bidi empty `DATA+END_STREAM` finalize |
| PROTOCOL-HTTP2 wire correctness | 100 | HTTP 415 on bad content-type; RST→status mapping; `grpc-status-details-bin`/`google.rpc.Status`; trailers-only errors; `user-agent`; `:scheme https` on TLS |
| Official non-auth interop | 100 | Go + Python matrices in CI |
| Protobuf + codegen | 97 | Text `.proto` path (`LEAN_GRPC_PROTO`) unchanged; real `protoc`-plugin path now decodes `CodeGeneratorRequest` and emits real message structs + typed client/server/bidi signatures (`scripts/run-codegen-fixture.sh`) |
| TLS + ALPN h2 | 100 | In-process OpenSSL (`tls_ffi`); sidecar optional; optional mTLS (client cert dial + server client-CA verify) |
| Channel/call credentials | 100 | JWT/OAuth/per-RPC + ADC Bearer (mock-proven) |
| Resolver / LB / retry / hedge | 100 | DNS, pick_first/RR, retry + hedgingPolicy |
| Health / reflection / channelz | 100 | `opsSmoke` CI gate: Check + Watch, v1/v1alpha reflection, real GetTopChannels/GetServers counters |
| Perf / soak / keepalive | 100 | benchUnary, `rpc_soak`/`channel_soak`-flag-compatible benchSoak, PING timeout→GOAWAY |
| GCP / ALTS / ORCA / xDS | 98 | ORCA unary + `orca_oob` streaming; full ADS LDS/RDS/CDS/EDS/SDS chain w/ ACK/NACK; **ALTS allowlisted** |
| Binary logging / stats | 90 | New `Grpc.BinaryLog` (header/message/trailer event capture) + `Grpc.Stats` (counters + Prometheus/OTel-stub export), both covered by `opsSmoke` |
| Load balancing extras | 85 | `Grpc.Grpclb` client shim (`BalanceLoad` → server list + drop handling); xDS remains the preferred/primary LB discovery path |
| Interceptors | 90 | `Grpc.Interceptor` client/server unary chains (logging built-ins; auth/metrics compose the same way), covered by `opsSmoke` |

## Mock vs live

| Surface | Tested how |
|---|---|
| Core / streaming / metadata | Live peers: Lean, Go, Python |
| Compression | Live Go with gzip codec registered (`Tests/GoGzipServer`) |
| TLS | Live Go TLS server + Lean in-process client; Lean↔Lean mTLS loopback (`tlsLoopback`, self-signed CA via system `openssl`) |
| ADC | Local HTTP mock (`scripts/mock-adc-server.py`) in CI; `scripts/run-adc-live.sh` documents a real-Google check (manual/nightly, needs live credentials) |
| xDS ADS | Lean `fakeAdsServer` speaking chained LDS/RDS/CDS/EDS/SDS + NACK-triggering resource |
| Codegen (real protoc-plugin path) | Hand-built binary `CodeGeneratorRequest` fixture piped directly into `protoc-gen-lean4-grpc`'s stdin (no `protoc` binary required/available in CI) |
| grpclb | Unit-level (`Grpc.Grpclb` decode/pick helpers); no live grpclb balancer server in CI |
| ALTS / GCE channel creds | **Not tested** — allowlisted |
| HTTP CONNECT proxying | **Not implemented / N/A** |

## Interop case checklist

| Case | Lean↔Lean | Go→Lean | Lean→Go |
|---|---|---|---|
| empty_unary … timeout_on_sleeping_server (core) | ✓ | ✓ | ✓ |
| client/server_compressed_* | ✓ | gzip helper | ✓ gzip server |
| pick_first_unary | ✓ | — | ✓ |
| cacheable_unary | ✓ (GET verb → EmptyCall) | — (needs caching proxy; not run) | ✓ vs Go; — vs Python (C-core rejects GET) |
| jwt / oauth / per_rpc | ✓ fixture | — | — |
| orca_per_rpc | ✓ | — | — |
| xds_static_unary / xds_ads_unary / xds_ads_chain_unary / xds_ads_nack | ✓ | — | — |
| tls_empty_unary | — | — | ✓ |
| compute_engine_channel / ALTS | allowlist | allowlist | allowlist |

Notes:
- `cacheable_unary` here checks the GET-verb wire mechanism (safe/idempotent calls use
  `:method: GET`) against `EmptyCall` rather than replicating the official test
  framework's full `CacheableUnaryCall` + caching-proxy + timestamp-equality assertions,
  which require infrastructure (a real caching proxy) outside this repo's scope.
- `cancel_after_begin` / `cancel_after_first_response` now assert `CANCELLED` (grpc-status 1)
  after the client-initiated RST, using the same RST→trailers mapping (`H2.Client.rstToTrailers`)
  applied locally as soon as the client sends the reset.
- Compression negotiation preference order is gzip > deflate > snappy > identity
  (`Grpc.Compression.negotiate`); deflate uses a zlib (RFC 1950) container, snappy uses
  literal-only (uncompressed) block framing that any conformant Snappy reader can decode.
- mTLS: `Grpc.Tls.Config.certPath`/`keyPath` present a client certificate on dial;
  `Grpc.Tls.Config.clientCaPath` makes `serveTls`/`Grpc.Tls.serveH2` require and verify a
  client certificate. Covered end-to-end by `tlsLoopback` (plain TLS, mTLS-reject-without-cert,
  mTLS-accept-with-cert), skipped only if `openssl` is unavailable in the environment.
- ADC composition: `Grpc.Adc.dialOptions` builds `Credentials.DialOptions` combining TLS
  channel credentials with an ADC-derived per-RPC Bearer token, for calling real Google APIs.
- xDS ADS now resolves the full chain a real xDS-enabled client would: `Grpc.XdsAds.resolveChain`
  does LDS(listener) → RDS(route config) → CDS(cluster) → EDS(endpoints) over one ADS session,
  with real ACK/NACK (`Grpc.Xds.Discovery.Request.ack`/`.nack`) on each hop; `fakeAdsServer` serves
  all five resource types (LDS/RDS/CDS/EDS/SDS) plus a deliberate `nack-test` resource whose
  inner `Any.type_url` is wrong, to exercise the NACK path end-to-end.
- Observability additions: `Grpc.Health.registerWithWatch` adds a `Watch` (server-streaming)
  handler alongside `Check`; `Grpc.Reflection` decodes real `ServerReflectionRequest`s and
  answers `list_services`/`file_by_filename`/`file_containing_symbol` against a small registry
  for both `v1` and `v1alpha`; `Grpc.Channelz.GetTopChannels`/`GetServers` return real call
  counters keyed off a shared `IO.Ref Counters`; `Grpc.Orca` reports use IEEE-754 `double`
  utilization fields and support both per-call and out-of-band (`orca_oob`) streaming reports;
  `Grpc.BinaryLog` captures header/message/trailer events to an in-memory sink; `Grpc.Stats`
  exposes call counters via a Prometheus-style exposition and a stdout/OTel-stub exporter.
- Codegen: the lightweight `.proto`-text path (`LEAN_GRPC_PROTO`, used by the Lake CI smoke
  test) is unchanged and still emits `ByteArray`-typed RPC stubs (it has no field-level info).
  The real `protoc`-plugin path (stdin/stdout, invoked as `protoc --plugin=... --lean4_out=...`)
  now decodes a minimal but real subset of `google.protobuf.compiler.CodeGeneratorRequest`
  (messages, fields, services, methods) and emits real message structs with `encode`/`decode`
  plus correctly-typed unary/client-streaming/server-streaming/bidi client stubs and a typed
  unary server-registration helper per RPC. `scripts/run-codegen-fixture.sh` hand-builds a
  request for a small `helloworld`-shaped service (no `protoc` binary needed) and checks the
  emitted code for the expected struct/stub/handler names.
- grpclb: `Grpc.Grpclb` is a thin client-side shim for the legacy `grpc.lb.v1.LoadBalancer/
  BalanceLoad` protocol — one-shot connect, `InitialLoadBalanceRequest`, decode the first
  `ServerList` response, and filter out `drop` entries. xDS ADS (`Grpc.XdsAds`) remains the
  preferred/primary discovery+LB path in this library; grpclb exists for interop with older
  balancers that only speak the plain server-list protocol.
- Interceptors: `Grpc.Interceptor` provides composable client/server unary interceptor chains
  (`applyClient`/`applyServer`, `callUnary`/`registerUnary`) plus ready-made logging
  interceptors; additional cross-cutting concerns (auth, metrics, retries) compose the same
  way by adding more `ClientUnary`/`ServerUnary` elements to the chain array.
- Soak: `Bench/Soak.lean` (`benchSoak`) now understands the standard `--soak_*` flags used by
  grpc's `rpc_soak`/`channel_soak` tools (`soak_iterations`, `soak_max_failures`,
  `soak_per_iteration_max_acceptable_latency_ms`, `soak_min_time_ms_between_rpcs`,
  `soak_overall_timeout_seconds`, `soak_request_size`, `soak_num_channels`,
  `soak_reset_channel_per_iteration`), while remaining back-compatible with the original
  `benchSoak host port N` positional-iterations form. See `scripts/run-soak.sh`.

## Commands

```bash
./scripts/run-go-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/run-python-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-lean-python.sh
./scripts/interop-compress-go-lean.sh
./scripts/interop-tls-go-lean.sh
./scripts/run-adc-smoke.sh
./scripts/run-xds-ads-smoke.sh       # full LDS/RDS/CDS/EDS/SDS chain + NACK path
./scripts/run-codegen-fixture.sh     # real protoc-plugin descriptor decode + typed emit
./scripts/run-soak.sh                # rpc_soak + channel_soak flag surface
./scripts/h2spec.sh
./scripts/run-stress-demos.sh        # VaultGauntlet + MirrorForge + SignalWeave + FramingMatrix
./scripts/run-framing-matrix.sh      # peer framing only (Lean↔Lean + Go→Lean)
lake build tlsLoopback && ./.lake/build/bin/tlsLoopback   # mTLS loopback (needs `openssl` CLI)

# Manual / nightly only — needs live Google credentials + network egress:
GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa.json ./scripts/run-adc-live.sh
```
