# Async IO model (v1.2.0)

lean-grpc uses Lean 4 `Std.Async.TCP` (libuv-backed) for sockets. Through
**v1.1.x** the public API collapsed every accept/connect/send/recv with
`.block`, so the library behaved as **synchronous `IO`** despite Async socket
constructors. That overstated “runs on Std.Async” — see
[GitHub #6](https://github.com/RileyBetts/lean-grpc/issues/6).

## v1.2.0 model

| Layer | Behavior |
|---|---|
| `H2.AsyncByteTransport` / `tcpTransportAsync` | Native `Async` send/recv — **no** `.block` |
| `H2.listenH2cAsync` / `connectH2cAsync` / `awaitResponseAsync` | Async accept/dial/RPC wait |
| `Grpc.Server.serveH2cAsync` / `Channel.unaryAsync` | Additive Async gRPC entry points |
| `ByteTransport` / `serveH2c` / `unary` / `connectH2c` | **Sync adapters** — `.block` at the edge only |
| In-process TLS (`SSL_read` / `SSL_write`) | Still **blocking FFI**; wrapped via `AsyncByteTransport.ofBlocking` |

```text
  App (Async) ──► serveH2cAsync / unaryAsync
                      │
                      ▼
              AsyncByteTransport (TCP)     ← zero .block on h2c hot path
                      │
                      ▼
                 Std.Async.TCP + UV loop

  App (IO) ──► serveH2c / unary  ──► (asyncPath).block   ← explicit adapter
```

## UV loop ownership

Prefer **one** event-loop owner per process. Nested `.block` inside
`IO.asTask` workers on the same loop is fragile (historical
`TrailersLoopback` note). The Async listen path schedules connections with
`Std.Async.background` instead.

## TLS caveat (v1.2.0)

OpenSSL in `native/tls_ffi.c` is blocking. `serveTls` / `connectH2` remain
correct and tested, but they are **not** end-to-end async. Do not claim TLS is
async until a nonblocking BIO or off-loop worker pool lands (follow-up issue).

## Migration

| Need | Use |
|---|---|
| Compose without blocking the loop (h2c) | `*Async` APIs |
| Existing code / lean-compliance | Keep `IO` APIs (adapters) |
| mTLS AuthN | `serveTls` + `registerWithContext` (sync FFI underneath) |

Pin: `@ "v1.2.0"`.
