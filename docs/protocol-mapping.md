# Protocol mapping

How lean-grpc implements [gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md) and related conventions. This is the lean-grpc-owned mapping doc; the upstream PROTOCOL-HTTP2 text remains normative for the wire format.

## Request

| Protocol atom | lean-grpc |
|---|---|
| `:method` | `POST` by default; `GET` for the wire-level `cacheable_unary` check |
| `:scheme` | `http` on h2c; `https` when channel credentials are TLS |
| `:path` | `/{service}/{method}` |
| `:authority` | Dial host / `DialOptions.authority` |
| `te` | `trailers` |
| `content-type` | `application/grpc+proto` |
| `user-agent` | `grpc-lean/<version>` |
| `grpc-timeout` | Parsed by `Metadata.parseTimeoutMs` (`H`/`M`/`S`/`m`/`u`/`n`) |
| `grpc-encoding` / `grpc-accept-encoding` | identity, gzip, deflate, snappy |
| Custom metadata | ASCII via `Metadata.add`; binary via `addBin` (`*-bin`, unpadded base64 preferred) |

Length-prefixed messages: 1-byte compressed flag + 4-byte big-endian length + payload (`Grpc.Message`). Compression contexts are **not** shared across messages.

## Response

| Protocol atom | lean-grpc |
|---|---|
| `:status 200` | Normal success and most gRPC errors |
| HTTP **415** | Content-type does not start with `application/grpc` |
| Response headers | `:status`, `content-type`, optional `grpc-encoding` |
| Trailers | `grpc-status`, optional `grpc-message` (percent-encoded), optional `grpc-status-details-bin` |
| Trailers-only | Single HEADERS+END_STREAM with `:status` + content-type + status trailers (unimplemented, zero timeout) |

`grpc-status-details-bin` carries serialized `google.rpc.Status` (`Proto.WellKnown.RpcStatus`). Details are rejected when status is OK or when the embedded code contradicts `grpc-status`.

## RST_STREAM → gRPC status

Implemented in `H2.Client.rstToTrailers` / stream `rstErrorCode`:

| HTTP/2 code | gRPC |
|---|---|
| NO_ERROR, PROTOCOL_ERROR, INTERNAL_ERROR, FLOW_CONTROL_ERROR, SETTINGS_TIMEOUT, FRAME_SIZE_ERROR, COMPRESSION_ERROR, CONNECT_ERROR | INTERNAL |
| REFUSED_STREAM | UNAVAILABLE |
| CANCEL | CANCELLED |
| ENHANCE_YOUR_CALM | RESOURCE_EXHAUSTED |
| INADEQUATE_SECURITY | PERMISSION_DENIED |

Client-initiated cancel sets local `rstErrorCode` so waiters observe CANCELLED without hanging.

## Connection management

| Feature | Behavior |
|---|---|
| SETTINGS | Exchanged after preface; duplicate SETTINGS ACK avoided (C-core/Python) |
| WINDOW_UPDATE / flow control | Connection + stream windows; pending send queue |
| PING | Keepalive; unanswered → GOAWAY + drop pool |
| GOAWAY | `wentAway`; in-flight may finish; new streams → UNAVAILABLE |
| PUSH_PROMISE | Connection error (PROTOCOL_ERROR) — clients do not accept push |
| CONTINUATION | Supported for large header blocks |

HTTP/2 conformance is gated by **h2spec** (`scripts/h2spec.sh`): 145 passed, 1 skipped, 0 failed.

## Timeouts and deadlines

- Client sends `grpc-timeout` and enforces wall-clock deadline in `awaitResponse` (RST + DEADLINE_EXCEEDED).
- Server treats parsed `0` timeout as immediate DEADLINE_EXCEEDED (trailers-only).
- Nanosecond unit maps to `0` ms (immediate); microseconds coarsen to ≥1 ms when non-zero.

## Compression

| Algorithm | Notes |
|---|---|
| identity | Default |
| gzip | Peer path via zlib helper / system `gzip`; stored-deflate fallback |
| deflate | zlib / RFC 1950-style container |
| snappy | Literal-block framing for interop |

Negotiation preference: gzip > deflate > snappy > identity. Message Compressed-Flag must be 0 when encoding is omitted.

## Security

| Mode | Mapping |
|---|---|
| h2c | Cleartext HTTP/2 (dev / mesh sidecar) |
| TLS 1.2+ ALPN `h2` | `Grpc.Native.Tls` / OpenSSL |
| mTLS | Client cert+key; server `clientCaPath` |
| Call credentials | `authorization: Bearer …` |
| ADC | SA JWT exchange or GCE metadata (mock in CI) |
| ALTS | **Not implemented** — allowlisted |

HTTP CONNECT proxying is out of scope (direct dial only).

## Name resolution and LB

| Mechanism | Mapping |
|---|---|
| `host:port` / `dns:///host:port` | Resolver + optional multi-A lookup |
| `pick_first` / `round_robin` | Balancer; RR picks per RPC |
| Service config JSON | timeout, retry, hedging, LB policy |
| `xds:///name` | ADS LDS→RDS→CDS→EDS (+ SDS stub) |
| grpclb | Optional thin `BalanceLoad` client |

## Standard services

| Service | Support |
|---|---|
| `grpc.health.v1.Health` | `Check` + `Watch` |
| Server reflection v1 / v1alpha | list_services, file_by_filename, file_containing_symbol (registry-backed) |
| channelz | GetTopChannels / GetServers with live counters |
| ORCA | Per-RPC trailer + OOB stream |

## Interop coverage

Official non-auth cases are exercised Lean↔Lean, Go↔Lean, and Python↔Lean (see [conformance.md](conformance.md)). Intentionally limited or skipped:

| Case | Reason |
|---|---|
| Full `cacheable_unary` | Needs caching proxy; Python rejects GET |
| Live Google auth / ADC | Mock CI; live script manual |
| ALTS / GCE channel | Allowlisted |
| CONNECT | N/A |

## References

- Upstream: [PROTOCOL-HTTP2.md](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)
- Interop: [interop-test-descriptions.md](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md)
- HTTP/2: [RFC 9113](https://httpwg.org/specs/rfc9113.html)
- Status details: `google.rpc.Status` in [googleapis](https://github.com/googleapis/googleapis/blob/master/google/rpc/status.proto)
