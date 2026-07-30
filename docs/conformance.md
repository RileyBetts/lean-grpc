# Conformance & interop scorecard

**Target:** near [grpc-go / official interop](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md) parity (Phases 1–9 hard; Phase 10 GCP allowlisted).

| Metric | Score |
|---|---|
| vs grpc-go app surfaces (plan 100) | **~97 implemented / ~94 tested** |
| h2spec | **145/146 pass, 1 skipped** (full suite hard CI) |
| Official non-auth interop | Lean↔Lean full; Go↔Lean stock client matrix green |

## Scorecard by area

| Area | % | Notes |
|---|---|---|
| HTTP/2 + HPACK (h2spec) | 100 | Phase 1 — full hard gate |
| Core RPC + duplex + deadlines | 95 | Phase 2 — incremental FullDuplex; mid-RPC deadline RST |
| Official non-auth interop | 95 | Phase 3 — compressed_* included |
| Protobuf + codegen | 90 | Phase 4 — text plugin + typed abbrevs; descriptor path stub |
| TLS + ALPN h2 | 90 | Phase 5 — OpenSSL `tls_proxy` + certs; Lean serves h2c behind it |
| Channel/call credentials | 85 | Phase 6 — token/JWT/composite; GCP cases → Phase 10 |
| Resolver / LB / retry | 90 | Phase 7 — DNS parse, pick_first/RR, retry policy, pick_first_unary |
| Health / reflection / channelz | 85 | Phase 8 — register APIs + unary smoke codecs |
| Perf / soak / keepalive | 85 | Phase 9 — benchUnary, benchSoak CI gate; idle PING |
| GCP / ALTS / ORCA / xDS | 20 | Phase 10 — API stubs + allowlist only |

## Interop case checklist

| Case | Lean↔Lean | Go→Lean | Lean→Go |
|---|---|---|---|
| empty_unary | ✓ | ✓ | ✓ |
| large_unary | ✓ | ✓ | ✓ |
| status_code_and_message | ✓ | ✓ | ✓ |
| custom_metadata | ✓ | ✓ | ✓ |
| cancel_after_begin | ✓ | ✓ | ✓ |
| cancel_after_first_response | ✓ | ✓ | ✓ |
| timeout_on_sleeping_server | ✓ | ✓ | ✓ |
| special_status_message | ✓ | ✓ | ✓ |
| unimplemented_method | ✓ | ✓ | ✓ |
| unimplemented_service | ✓ | ✓ | ✓ |
| server_streaming | ✓ | ✓ | ✓ |
| client_streaming | ✓ | ✓ | ✓ |
| ping_pong (true duplex) | ✓ | ✓ | ✓ |
| empty_stream | ✓ | ✓ | ✓ |
| client_compressed_unary | ✓ | via gzip-go-lean | ✓ (probe soft on Go) |
| server_compressed_unary | ✓ | — (Go client build) | ✓ |
| client_compressed_streaming | ✓ | — (Go client build) | ✓ (probe soft on Go) |
| server_compressed_streaming | ✓ | — (Go client build) | ✓ |
| pick_first_unary | ✓ | — | ✓ |
| jwt_token_creds / oauth2 / per_rpc | API | allowlist | allowlist |
| compute_engine_* / ALTS / xDS | stub | allowlist | allowlist |

## Phase 10 allowlist

See `Grpc.Gcp.deferredCases` — live GCP / ALTS / ORCA / xDS deferred with documented reasons.

## Commands

```bash
lake build bytesTests hpackTests h2Tests grpcTests interopServer interopClient
./.lake/build/bin/grpcTests
./scripts/h2spec.sh
./scripts/run-go-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/interop-tls-go-lean.sh
./scripts/build_native.sh   # zlib_helper + tls_proxy
```

## Perf (local reference)

| Bench | Result |
|---|---|
| lean↔lean unary (n=200) | record via `benchUnary` → update here |
| soak (n=30 helloworld) | hard-gated in CI (`benchSoak`) |
