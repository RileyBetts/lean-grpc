# Getting started

This guide gets a Lean 4 unary gRPC server and client running on h2c with **typed generated stubs**, then shows TLS dial and Lake dependency usage.

**Requirements:** Lean 4.32+ (see `lean-toolchain`), OpenSSL headers for the `Grpc` library (`libssl-dev` or `./scripts/fetch-openssl-headers.sh`). Peer gzip optionally uses a zlib helper (`./scripts/build_native.sh`) or system `gzip`.

Package version: **1.3.0** (`lakefile.lean` / `Grpc.version`).

## Build the repo

```bash
git clone https://github.com/RileyBetts/lean-grpc.git
cd lean-grpc
lake build
lake build helloworldServer helloworldClient grpcTests
./.lake/build/bin/grpcTests
```

Native OpenSSL FFI object (linked by `Grpc`):

```bash
./scripts/build_native.sh   # also builds optional zlib_helper for peer gzip
```

## Run helloworld (typed stubs)

```bash
./scripts/gen-helloworld.sh   # regenerates Examples/Helloworld/Generated.lean
lake build helloworldServer helloworldClient
./.lake/build/bin/helloworldServer &
./.lake/build/bin/helloworldClient 127.0.0.1 50051 World
# → Hello, World
```

### Minimal typed server

```lean
import Grpc
import Examples.Helloworld.Generated

def main : IO Unit := do
  let mut s := Grpc.Server.empty
  s := helloworld.registerGreeterSayHello s fun req => do
    pure ({ message := s!"Hello, {req.name}" }, Grpc.Status.ok)
  Grpc.Server.serveH2c s { host := "127.0.0.1", port := 50051 }
```

### Minimal typed client

```lean
import Grpc
import Examples.Helloworld.Generated

def main : IO Unit := do
  let ch ← Grpc.Channel.connectH2c "127.0.0.1" 50051
  let stub : helloworld.GreeterStub := { channel := ch }
  match ← stub.SayHello { name := "Lean" } with
  | .ok reply => IO.println reply.message
  | .error e => IO.eprintln e
```

Raw `ByteArray` handlers (`Grpc.Server.register` + manual encode/decode) remain available; prefer generated stubs for new services. See [cookbook-unary.md](cookbook-unary.md).

## Dial with TLS

```lean
let ch ← Grpc.Channel.dial "api.example.com:443" {
  channel := .tls {
    caPath := some "/etc/ssl/certs/ca-certificates.crt"
    serverName := some "api.example.com"
  }
}
```

mTLS: set `certPath` / `keyPath` on the client config; on the server set `clientCaPath` and use `Grpc.Server.serveTls`. Details: [tls-envoy.md](tls-envoy.md), [cookbook-interceptors.md](cookbook-interceptors.md).

## Targets and service config

```lean
-- dns:///host:port or host:port
let ch ← Grpc.Channel.dial "dns:///127.0.0.1:50051" {}
  (Grpc.ServiceConfig.parse "{\"loadBalancingPolicy\":\"round_robin\",\"timeout\":\"5s\"}")

-- xDS when LEAN_GRPC_XDS_BOOTSTRAP points at a bootstrap JSON
let ch ← Grpc.Channel.dial "xds:///my-service" {}
```

Override resolved addresses in tests with `LEAN_GRPC_RESOLVE_ADDRS=127.0.0.1:50051,127.0.0.1:50052`.

## Streaming

Prefer the batch helpers, or `openStream` for interactive duplex:

```lean
let (msgs, st) ← Grpc.Channel.serverStream ch "svc" "ServerStream" req
let res ← Grpc.Channel.clientStream ch "svc" "ClientStream" reqs
let (echo, st) ← Grpc.Channel.bidiStream ch "svc" "Bidi" reqs
```

Server side:

```lean
s := Grpc.Server.registerServerStreamTyped s "svc" "ServerStream"
  Req.decode Resp.encode fun req => pure (#[resp1, resp2], Grpc.Status.ok)
```

Full walkthrough: [cookbook-streaming.md](cookbook-streaming.md). Example: `Examples/RouteGuide/`.

## Metadata, deadlines, compression

```lean
let md := Grpc.Metadata.empty
  |> (Grpc.Metadata.add · "x-request-id" "abc")
  |> (Grpc.Metadata.addBin · "x-bin" (ByteArray.mk #[1, 2, 3]))
let res ← Grpc.Channel.unary ch "svc" "Method" req md (some "2S") .gzip
```

Timeout strings follow gRPC (`H`/`M`/`S`/`m`/`u`/`n`). Compression algorithms: `identity`, `gzip`, `deflate`, `snappy` (negotiate prefers gzip).

## Codegen

**Descriptor path (typed messages + stubs — preferred):**

```bash
./scripts/gen-helloworld.sh
# or: ./scripts/run-codegen-fixture.sh
```

**Text path (Lake smoke; ByteArray placeholders only):**

```bash
LEAN_GRPC_OUT=/tmp/gen LEAN_GRPC_PROTO=Examples/helloworld.proto \
  ./.lake/build/bin/protoc-gen-lean4-grpc
```

**Real protoc plugin:**

```bash
lake build protocGenLean4Grpc
protoc --plugin=protoc-gen-lean4-grpc=./.lake/build/bin/protoc-gen-lean4-grpc \
  --lean4_out=. your.proto
```

Current descriptor-codegen limits: nested messages / `repeated` / `oneof` / maps are incomplete — RouteGuide still uses hand-written `Proto.RouteGuide` codecs. See [api-reference.md](api-reference.md).

## Depend from another Lake project

**System deps:** OpenSSL (`libssl-dev` / Homebrew `openssl`, plus `pkg-config`). Fallback: `./scripts/fetch-openssl-headers.sh`.

In your `lakefile.lean`:

```lean
require «lean-grpc» from git
  "https://github.com/RileyBetts/lean-grpc.git" @ "v1.3.0"
```

Then `import Grpc` (and `Proto` if you use the bundled codecs). Public libs: `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc`. Linking OpenSSL (`-lssl -lcrypto`) is pulled in via the `Grpc` Lake library (not via Bytes/Hpack/H2 alone). For peer gzip against foreign stacks, set `LEAN_GRPC_ZLIB_HELPER` after `./scripts/build_native.sh`. Full packaging notes: [packaging.md](packaging.md). Hosted docs: [rileybetts.ai/oss/lean-grpc](https://rileybetts.ai/oss/lean-grpc).

After [Reservoir](https://reservoir.lean-lang.org/) indexes the package you can use `require «lean-grpc»` without a git URL. Pin a commit SHA if the `v1.3.0` tag is not yet on the remote you use.

## Next steps

- [Cookbook: typed unary](cookbook-unary.md)
- [Cookbook: streaming](cookbook-streaming.md)
- [Cookbook: interceptors / auth / mTLS](cookbook-interceptors.md)
- [Packaging](packaging.md) — Lake/Reservoir consumer contract
- [Architecture](architecture.md) — how the stack layers
- [API reference](api-reference.md) — module catalogue
- [Conformance](conformance.md) — what is tested vs allowlisted
- Examples: `Examples/Helloworld`, `Examples/RouteGuide`
- Interop: `./scripts/run-python-to-lean.sh`, `./scripts/run-go-to-lean.sh`, `./scripts/run-rust-to-lean.sh`
