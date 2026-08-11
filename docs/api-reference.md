# API reference

Lean module catalogue for consumers. Signatures are summarized; see source under `Grpc/`, `H2/`, `Proto/` for full definitions. Version string: `Grpc.version` (currently `1.3.0`). Async vs sync IO: [async-io.md](async-io.md).

Import umbrella: `import Grpc` (pulls status, channel, server, credentials, TLS, xDS, ops, etc.). Add `import Proto` for bundled message codecs.

The Lake lib `Proofs` is **not** part of the consumer API (CI-only compile-time theorems); see [proofs.md](proofs.md).

---

## Status and metadata

### `Grpc.Status` / `Grpc.StatusCode`

gRPC status codes `ok` … `unauthenticated`. Helpers: `Status.ok`, `.unimplemented`, `.internal`, `.deadlineExceeded`, `.cancelled`, `.unavailable`, `.invalidArgument`, `.permissionDenied`, `.resourceExhausted`.

Optional `detailsBin : Option ByteArray` holds encoded `google.rpc.Status` when status ≠ OK.

### `Grpc.StatusDetails`

- `encode` / `decode` — `google.rpc.Status` via `Proto.WellKnown.RpcStatus`
- `attachBin` — add `grpc-status-details-bin`
- `fromMetadata` — read + reject contradicting codes / details on OK

### `Grpc.Metadata`

| API | Purpose |
|---|---|
| `add` / `get?` | ASCII metadata |
| `addBin` / `getBin?` | `-bin` base64 (padded/unpadded) |
| `percentEncode` / `percentDecode` | `grpc-message` |
| `parseTimeoutMs` | `10S`, `100m`, `1H`, `100u`, `1n`, … |
| `statusHeaders` / `http200` / `http415` / `trailersOnly` | Response header builders |
| `userAgent` / `schemeHttp` / `schemeHttps` / `methodPost` / `methodGet` | Pseudo/call-definition headers |

---

## Messages and compression

### `Grpc.Message`

Length-prefixed gRPC frames (`Compressed-Flag` + 4-byte length + payload).

- `encode` / `decodeOne` / `decodeAll` — pure (stored gzip for `.gzip`)
- `encodeIO` / `decode*IO` — peer-compatible inflate/deflate via zlib helper / system gzip

### `Grpc.Compression.Algorithm`

`identity` | `gzip` | `deflate` | `snappy`

- `negotiate` — preference gzip > deflate > snappy > identity
- `compressIO` / `decompressIO` — peer paths where available

---

## Client

### `Grpc.CallResult`

`status`, `message` (decoded payload bytes), `headers`, `trailers`.

### `Grpc.Client.unaryCall` / `unaryCallAsync`

Low-level unary on an `H2.ClientConn` (scheme http/https, user-agent, compression).

### `Grpc.Channel`

| API | Purpose |
|---|---|
| `connectH2c host port` | Plain h2c channel |
| `dial target opts svc?` | Resolve + balanc + connect (`dns:///`, `host:port`, `xds:///`) |
| `unary` / `unaryAsync` | Unary RPC (Async = no `.block` on h2c call path; hedge/retry via sync adapter) |
| `openStream ch service method metadata?` | Interactive bidi client stream |
| `serverStream` / `clientStream` / `bidiStream` | Batch streaming helpers (messages + status) |
| `get` / `goAway` / `close` | Connection pool / drain |
| `maxMsgSize` / `maxSendMsgSize` / `maxRecvMsgSize` | Message limits (default 4 MiB) |
| `keepaliveMs` | Idle PING interval |

`Credentials.DialOptions`: `channel`, `call`, `authority`.

### `Grpc.Stream`

`ClientStream` with `StreamWriter.send` / `sendAll` / `halfClose` and `StreamReader.recv?` / `recvAll` / `status`. Server handler abbrevs: `ServerStreamHandler`, `ClientStreamHandler`, `BidiStreamHandler`.

### `Grpc.Interceptor`

Unary middleware:

- `registerUnary` / `callUnary`
- `registerUnaryWithContext` / `applyServerWithContext`
- `applyServer` / `applyClient`
- Built-ins: `loggingServer`, `loggingClient`, `loggingServerWithContext`, `requirePeerIdentity`, `bearerMetadata`

---

## Server

### `Grpc.PeerIdentity` / `Grpc.ServerCallContext`

Verified mTLS peer certificate identity (OpenSSL; subject DN is **RFC 2253**):

| Field | Notes |
|---|---|
| `subjectDn` | Full subject DN |
| `commonName` | CN if present; else empty |
| `dnsSans` / `uriSans` | SAN lists (URI SANs for SPIFFE-style IDs) |
| `fingerprintSha256` | Hex SHA-256 of DER cert |
| `serial` | Hex serial |

`ServerCallContext`: `peerIdentity`, inbound `metadata` (non-pseudo headers), `methodPath`, `mtlsRequired`.

`Grpc.Native.Tls.peerIdentity?` extracts identity from an accepted TLS connection.

### `Grpc.Server`

| API | Purpose |
|---|---|
| `empty` | Empty registry |
| `register` | Unary `ByteArray → IO (ByteArray × Status)` (ignores context) |
| `registerWithContext` | Unary with `ServerCallContext` (peer identity + metadata) |
| `registerTyped` / `registerTypedWithContext` | Typed unary adapters |
| `registerServerStream` / `registerClientStream` / `registerBidi` | Streaming (raw bytes; context deferred) |
| `registerServerStreamTyped` / `registerClientStreamTyped` / `registerBidiTyped` | Streaming with decode/encode adapters |
| `serveH2c` / `serveH2cAsync` | Listen h2c (`peerIdentity = none`); Async path has no `.block` on accept/send/recv |
| `serveTls` / `serveTlsAsync` | Listen TLS+ALPN; per-connection peer identity → context handlers (OpenSSL **off-loop** under Async in v1.3.0) |
| `maxMsgSize` | Inbound limit |

Bad `content-type` → HTTP **415**. Unknown method / zero timeout → trailers-only gRPC status.

### Ops registration

| Module | Register |
|---|---|
| `Grpc.Health` | `register` / `registerWithWatch` (`Check` + streaming `Watch`) |
| `Grpc.Reflection` | `register` (v1 + v1alpha list/file/symbol) |
| `Grpc.Channelz` | `register` with `IO.Ref Counters`; `recordSuccess` / failures |

---

## Credentials and TLS

### `Grpc.Credentials`

- `ChannelCredentials.insecure` | `.tls Tls.Config`
- `CallCredentials.accessToken` / `.jwt` / `.oauth2` / `.perRpc` / `.composite`
- `DialOptions`

### `Grpc.Tls.Config`

`certPath`, `keyPath`, `caPath`, `clientCaPath`, `serverName`, `alpn` (default `["h2"]`).

- Client mTLS: set `certPath` + `keyPath`
- Server mTLS: set `clientCaPath` on serve — verified peer identity is available via `registerWithContext` / `ServerCallContext.peerIdentity`
- `Tls.serveH2` takes `mkHandler : Option PeerIdentity → H2.StreamHandler`; failed accepts/handshakes are logged and the listen loop continues

Env: `LEAN_GRPC_TLS_PROXY`, `LEAN_GRPC_TLS_INSECURE_FALLBACK=1` (dev only).

### `Grpc.Adc`

- `accessToken` / `callCredentials` / `clearCache`
- `dialOptions caPath? serverName?` — TLS channel + ADC Bearer
- Live check: `scripts/run-adc-live.sh` (manual)

### `Grpc.Gcp`

Allowlisted: `deferredCases` = GCE channel credentials, ALTS. ADC call credentials are implemented.

---

## Resolver, LB, retry, service config

### `Grpc.Resolver`

`parseTarget`, `resolve` (multi-addr via `getent ahosts`; `LEAN_GRPC_RESOLVE_ADDRS` override).

### `Grpc.Balancer`

`Policy.pickFirst` | `.roundRobin`; `create`, `pick` (RR advances per call).

### `Grpc.ServiceConfig`

`parse` JSON for `loadBalancingPolicy` / `loadBalancingConfig`, `timeout`, `retryPolicy`, `hedgingPolicy`, `methodConfig`.

### `Grpc.Retry`

`shouldRetry`, `backoffMs` from `RetryPolicy`.

Channel implements sequential retry and **parallel** hedging (RST losers).

### `Grpc.Grpclb`

`fetchServerList`, `decodeServerList`, `liveAddresses` — thin `BalanceLoad` shim.

---

## xDS

### `Grpc.Xds` / `Grpc.Xds.Discovery` / `Grpc.XdsAds`

- Type URLs for LDS / RDS / CDS / EDS / SDS
- DiscoveryRequest/Response encode/decode; `Request.ack` / `.nack`
- `resolveChain` — LDS→RDS→CDS→EDS
- `resolveFromEnv` — `LEAN_GRPC_XDS_BOOTSTRAP`
- CI: `Tests/FakeAdsServer.lean`, `scripts/run-xds-ads-smoke.sh`

---

## Observability extras

| Module | Highlights |
|---|---|
| `Grpc.Orca` | IEEE double utilization; per-RPC trailer + `orca_oob` |
| `Grpc.BinaryLog` | Event sink for headers/messages/trailers |
| `Grpc.Stats` | Counters; Prometheus text / OTel-stub exporter |
| `Grpc.Jwt` | Unsigned JWT fixture helpers for interop |

---

## HTTP/2 (`H2`)

Consumers usually stay in `Grpc.*`. Useful lower APIs:

| API | Purpose |
|---|---|
| `H2.Client.connectH2c` / `connectH2cAsync` / `connectTransport` | Client connection |
| `H2.Client.startRequest` / `awaitResponse` / `unary` (+ `*Async`) / `resetStream` | Streams |
| `H2.Client.rstToTrailers` | RST → synthetic gRPC trailers |
| `H2.Server.listen` / `listenAsync` / `serveConn` / `serveConnAsync` | Server accept loop |
| `H2.AsyncByteTransport` / `tcpTransportAsync` | Native Async send/recv (h2c) |
| `H2.ByteTransport` / `tcpTransport` | Sync facade (`.block` adapters) |
| `H2.handleFrame` / `ConnState` | State machine (tested via h2spec) |

---

## Protobuf (`Proto`)

| Module | Contents |
|---|---|
| `Proto.Wire` | Varint, length-delimited, field decode helpers |
| `Proto.WellKnown` | `AnyMsg`, map entries, `RpcStatus` (`google.rpc.Status`) |
| `Proto.Message` | Interop messages (`SimpleRequest`, streaming, …) |
| `Proto.RouteGuide` | RouteGuide example types |

---

## Codegen (`Grpc.Codegen`)

Executable `protoc-gen-lean4-grpc`:

1. **Text `.proto`** (`LEAN_GRPC_PROTO` / argv) → `Generated.lean` with `ByteArray` RPC stubs  
2. **protoc plugin** — stdin `CodeGeneratorRequest` → stdout response with message structs + typed unary/streaming **client** stubs + typed unary **server** register helpers  

Regenerate the helloworld example: `scripts/gen-helloworld.sh` (uses the same descriptor fixture as `scripts/run-codegen-fixture.sh`).

**Current limits (descriptor path):** nested messages, `repeated`, `oneof`, maps, and many scalar wire types are incomplete or fall back to `bytes`. Streaming server registration is not emitted — use `Server.register*Typed`. Stream client stubs are batch (send-all / recv-all), not interactive duplex.

---

## Errors and mapping

| Condition | Application sees |
|---|---|
| Peer `grpc-status` | Matching `StatusCode` |
| HTTP 415 | `invalidArgument` (“unsupported media type”) |
| Other non-200 HTTP | `unknown` (or existing grpc-status) |
| RST CANCEL | `cancelled` |
| RST REFUSED_STREAM | `unavailable` |
| RST ENHANCE_YOUR_CALM | `resourceExhausted` |
| Client deadline | `deadlineExceeded` (+ RST to peer) |
| Peer GOAWAY (new streams) | `unavailable` |
| Oversized message | `resourceExhausted` |

Details: [protocol-mapping.md](protocol-mapping.md).
