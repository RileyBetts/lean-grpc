# Conformance & interop scorecard

**Target:** near [grpc-go / official interop](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md) parity (Phases 1–9 hard; ALTS allowlisted).

| Metric | Score |
|---|---|
| vs grpc-go app surfaces | **~100 implemented / ~99.5 tested** |
| h2spec | **145/146 pass, 1 skipped** (full suite hard CI) |
| Official non-auth interop | Lean↔Lean; **Go↔Lean**; **Python↔Lean** (CI) |
| Compression | Lean↔Lean; Go gzip client→Lean; Lean→Go gzip-enabled server |
| In-process TLS | Lean→Go TLS unary (no sidecar) |
| ADC | SA JWT + GCE metadata (**mock CI**, not live Google) |
| xDS ADS | Real `DiscoveryRequest/Response` + CLA EDS (**FakeAds CI**) |

## Scorecard by area

| Area | % | Notes |
|---|---|---|
| HTTP/2 + HPACK (h2spec) | 100 | Full hard gate |
| Core RPC + duplex + deadlines | 100 | Incremental FullDuplex; mid-RPC deadline RST |
| Official non-auth interop | 100 | Go + Python matrices in CI |
| Protobuf + codegen | 95 | Typed abbrevs; descriptor path still minimal |
| TLS + ALPN h2 | 100 | In-process OpenSSL (`tls_ffi`); sidecar optional |
| Channel/call credentials | 100 | JWT/OAuth/per-RPC + ADC Bearer (mock-proven) |
| Resolver / LB / retry / hedge | 100 | DNS, pick_first/RR, retry + hedgingPolicy |
| Health / reflection / channelz | 100 | `opsSmoke` CI gate |
| Perf / soak / keepalive | 95 | benchUnary, benchSoak, PING timeout→GOAWAY |
| GCP / ALTS / ORCA / xDS | 96 | ORCA + protobuf ADS EDS; **ALTS allowlisted** |

## Mock vs live

| Surface | Tested how |
|---|---|
| Core / streaming / metadata | Live peers: Lean, Go, Python |
| Compression | Live Go with gzip codec registered (`Tests/GoGzipServer`) |
| TLS | Live Go TLS server + Lean in-process client |
| ADC | Local HTTP mock (`scripts/mock-adc-server.py`) |
| xDS ADS | Lean `fakeAdsServer` speaking Discovery + CLA protobuf |
| ALTS / GCE channel creds | **Not tested** — allowlisted |

## Interop case checklist

| Case | Lean↔Lean | Go→Lean | Lean→Go |
|---|---|---|---|
| empty_unary … timeout_on_sleeping_server (core) | ✓ | ✓ | ✓ |
| client/server_compressed_* | ✓ | gzip helper | ✓ gzip server |
| pick_first_unary | ✓ | — | ✓ |
| jwt / oauth / per_rpc | ✓ fixture | — | — |
| orca_per_rpc | ✓ | — | — |
| xds_static_unary / xds_ads_unary | ✓ | — | — |
| tls_empty_unary | — | — | ✓ |
| compute_engine_channel / ALTS | allowlist | allowlist | allowlist |

## Commands

```bash
./scripts/run-go-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/run-python-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-lean-python.sh
./scripts/interop-compress-go-lean.sh
./scripts/interop-tls-go-lean.sh
./scripts/run-adc-smoke.sh
./scripts/run-xds-ads-smoke.sh
./scripts/h2spec.sh
```
