# Conformance & interop scorecard

**Target:** near [grpc-go / official interop](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md) parity (Phases 1–9 hard; live-GCP-only cases allowlisted).

| Metric | Score |
|---|---|
| vs grpc-go app surfaces (plan 100) | **~100 implemented / ~98 tested** |
| h2spec | **145/146 pass, 1 skipped** (full suite hard CI) |
| Official non-auth interop | Lean↔Lean full; Go↔Lean stock client matrix green |

## Scorecard by area

| Area | % | Notes |
|---|---|---|
| HTTP/2 + HPACK (h2spec) | 100 | Full hard gate |
| Core RPC + duplex + deadlines | 100 | Incremental FullDuplex; mid-RPC deadline RST |
| Official non-auth interop | 100 | compressed_* Lean↔Lean; Go stock matrix + gzip helper |
| Protobuf + codegen | 95 | Typed abbrevs; descriptor path still minimal |
| TLS + ALPN h2 | 100 | OpenSSL `tls_proxy` + CI `libssl-dev` |
| Channel/call credentials | 100 | JWT/OAuth/per-RPC fixture interop (Lean↔Lean) |
| Resolver / LB / retry / hedge | 100 | DNS, pick_first/RR, retry + hedgingPolicy parse |
| Health / reflection / channelz | 100 | `opsSmoke` CI gate |
| Perf / soak / keepalive | 95 | benchUnary, benchSoak, PING timeout→GOAWAY |
| GCP / ALTS / ORCA / xDS | 90 | ORCA trailer + xDS static bootstrap; live GCE/ALTS allowlisted |

## Interop case checklist

| Case | Lean↔Lean | Go→Lean | Lean→Go |
|---|---|---|---|
| empty_unary … timeout_on_sleeping_server (core) | ✓ | ✓ | ✓ |
| compressed_* | ✓ | gzip helper / — | partial |
| pick_first_unary | ✓ | — | ✓ |
| jwt_token_creds / oauth2_auth_token / per_rpc_creds | ✓ fixture | live GCP | — |
| orca_per_rpc | ✓ trailer smoke | custom LB | — |
| xds_static_unary | ✓ bootstrap | ADS stream | — |
| compute_engine_* / ALTS / google_default | allowlist | allowlist | allowlist |

## Phase 10 allowlist (live GCP only)

`Grpc.Gcp.deferredCases`: `computeEngineCreds`, `googleDefaultCredentials`, `computeEngineChannelCredentials`, `alts`.

## Commands

```bash
lake build grpcTests interopServer interopClient opsSmoke benchSoak
./.lake/build/bin/grpcTests
./scripts/h2spec.sh
./scripts/run-go-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/interop-tls-go-lean.sh
```
