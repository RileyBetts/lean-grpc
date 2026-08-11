# Async IO model (v1.3.0)

lean-grpc uses Lean 4 `Std.Async.TCP` (libuv-backed) for sockets. Through
**v1.1.x** the public API collapsed every accept/connect/send/recv with
`.block`, so the library behaved as **synchronous `IO`** despite Async socket
constructors. That overstated “runs on Std.Async” — see
[GitHub #6](https://github.com/RileyBetts/lean-grpc/issues/6).

## v1.2.0+ h2c model

| Layer | Behavior |
|---|---|
| `H2.AsyncByteTransport` / `tcpTransportAsync` | Native `Async` send/recv — **no** `.block` |
| `H2.listenH2cAsync` / `connectH2cAsync` / `awaitResponseAsync` | Async accept/dial/RPC wait |
| `Grpc.Server.serveH2cAsync` / `Channel.unaryAsync` | Additive Async gRPC entry points |
| `ByteTransport` / `serveH2c` / `unary` / `connectH2c` | **Sync adapters** — `.block` at the edge only |

## v1.3.0 TLS off-loop model

In-process OpenSSL (`SSL_read` / `SSL_write` / handshake) remains **blocking FFI**.
**v1.3.0** runs that FFI on **dedicated threads** so the UV loop is not stalled
([#10](https://github.com/RileyBetts/lean-grpc/issues/10)):

| Layer | Behavior |
|---|---|
| `H2.runOffLoop` / `AsyncByteTransport.ofBlockingOffLoop` | `IO.asTask .dedicated` + await — SSL off UV |
| `Tls.connectH2Async` / `serveH2Async` / `Server.serveTlsAsync` | Accept/handshake off-loop; conns on `background` |
| `Tls.connectH2` / `serveH2` / `serveTls` | Blocking `IO` (safe under `IO.asTask`; no nested `Async.block`) |

This is **off-loop blocking TLS**, not nonblocking BIO. Do not claim “fully async
OpenSSL” until a BIO/`WANT_READ` integration lands (follow-up issue).

```text
  App (Async) ──► serveH2cAsync / unaryAsync          (h2c, zero .block)
              └─► serveTlsAsync / connectH2Async      (TLS off-loop)
                      │
                      ▼
              dedicated Task ──► SSL_* (blocking FFI)
                      │
              UV loop stays free for Std.Async.TCP

  App (IO) ──► serveTls / connectH2  (plain blocking IO accept/dial)
```

## UV loop ownership

Prefer **one** event-loop owner per process. Nested `.block` inside
`IO.asTask` / `runOffLoop` workers is fragile (historical `TrailersLoopback`
note). Use pure `IO` for sync TLS helpers when already on a dedicated thread;
use `Std.Async.background` for connection scheduling under Async.

## Migration

| Need | Use |
|---|---|
| Compose without blocking the loop (h2c) | `*Async` APIs |
| Compose under Async without freezing UV (TLS) | `connectH2Async` / `serveTlsAsync` / `runOffLoop` |
| Existing code / lean-compliance | Keep `IO` APIs |
| mTLS AuthN | `serveTls` or `serveTlsAsync` + `registerWithContext` |

Pin: `@ "v1.3.0"`.
