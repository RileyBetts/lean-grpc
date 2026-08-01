# Getting started

This guide gets a Lean 4 unary gRPC server and client running on h2c, then shows TLS dial and Lake dependency usage.

**Requirements:** Lean 4.32+ (see `lean-toolchain`), OpenSSL headers for TLS (`libssl-dev` or `./scripts/fetch-openssl-headers.sh`), optional `zlib` for peer gzip.

## Build the repo

```bash
git clone https://github.com/RileyBetts/lean-grpc.git
cd lean-grpc
lake build
lake build helloworldServer helloworldClient grpcTests
./.lake/build/bin/grpcTests
```

Native helpers (peer gzip / TLS FFI objects):

```bash
./scripts/build_native.sh
```

## Run helloworld

```bash
lake build helloworldServer helloworldClient
./.lake/build/bin/helloworldServer &
./.lake/build/bin/helloworldClient 127.0.0.1 50051 World
# → Hello, World
```

### Minimal server

```lean
import Grpc
import Proto

def main : IO Unit := do
  let mut s := Grpc.Server.empty
  s := Grpc.Server.register s "helloworld.Greeter" "SayHello" fun reqBytes => do
    let req ← IO.ofExcept (Proto.HelloRequest.decode reqBytes)
    let reply : Proto.HelloReply := { message := s!"Hello, {req.name}" }
    return (Proto.HelloReply.encode reply, Grpc.Status.ok)
  Grpc.Server.serveH2c s { host := "127.0.0.1", port := 50051 }
```

### Minimal client

```lean
import Grpc
import Proto

def main : IO Unit := do
  let ch ← Grpc.Channel.connectH2c "127.0.0.1" 50051
  let res ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello"
    (Proto.HelloRequest.encode { name := "Lean" })
  let reply ← IO.ofExcept (Proto.HelloReply.decode res.message)
  IO.println reply.message
```

Handlers receive and return **protobuf bytes**. Use `Proto.*` codecs shipped with the repo, or generate stubs (see [Codegen](#codegen)).

## Dial with TLS

```lean
let ch ← Grpc.Channel.dial "api.example.com:443" {
  channel := .tls {
    caPath := some "/etc/ssl/certs/ca-certificates.crt"
    serverName := some "api.example.com"
  }
}
```

mTLS: set `certPath` / `keyPath` on the client config; on the server set `clientCaPath` and use `Grpc.Server.serveTls`. Details: [tls-envoy.md](tls-envoy.md).

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

Register streaming handlers on the server:

```lean
s := Grpc.Server.registerServerStream s "svc" "ServerStream" fun req => do
  pure (#[resp1, resp2], Grpc.Status.ok)
s := Grpc.Server.registerClientStream s "svc" "ClientStream" fun msgs => do
  pure (aggregated, Grpc.Status.ok)
s := Grpc.Server.registerBidi s "svc" "Bidi" fun msgs => do
  pure (echo, Grpc.Status.ok)
```

On the client, use `Grpc.Channel.openStream` for duplex, or the interop client cases in `Tests/Interop/Client.lean` as examples.

## Metadata, deadlines, compression

```lean
let md := Grpc.Metadata.empty
  |> (Grpc.Metadata.add · "x-request-id" "abc")
  |> (Grpc.Metadata.addBin · "x-bin" (ByteArray.mk #[1, 2, 3]))
let res ← Grpc.Channel.unary ch "svc" "Method" req md (some "2S") .gzip
```

Timeout strings follow gRPC (`H`/`M`/`S`/`m`/`u`/`n`). Compression algorithms: `identity`, `gzip`, `deflate`, `snappy` (negotiate prefers gzip).

## Codegen

**Text path (Lake smoke):**

```bash
LEAN_GRPC_OUT=/tmp/gen LEAN_GRPC_PROTO=Examples/helloworld.proto \
  ./.lake/build/bin/protoc-gen-lean4-grpc
# writes /tmp/gen/Generated.lean (ByteArray-typed stubs)
```

**Real protoc plugin path:**

```bash
lake build protocGenLean4Grpc
protoc --plugin=protoc-gen-lean4-grpc=./.lake/build/bin/protoc-gen-lean4-grpc \
  --lean4_out=. your.proto
```

Without `protoc` installed, `./scripts/run-codegen-fixture.sh` exercises the descriptor decode path.

## Depend from another Lake project

**System deps:** OpenSSL + zlib (`libssl-dev` / Homebrew `openssl`, plus `pkg-config` / `zlib`). Fallback: `./scripts/fetch-openssl-headers.sh`.

In your `lakefile.lean`:

```lean
require «lean-grpc» from git
  "https://github.com/RileyBetts/lean-grpc.git" @ "v0.5.0"
```

Then `import Grpc` (and `Proto` if you use the bundled codecs). Public libs: `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc`. Link needs OpenSSL (`-lssl -lcrypto`) and zlib (`-lz`) — see this package’s `moreLinkArgs`. Full packaging notes: [packaging.md](packaging.md).

## Next steps

- [Architecture](architecture.md) — how the stack layers
- [API reference](api-reference.md) — module catalogue
- [Conformance](conformance.md) — what is tested vs allowlisted
- Examples: `Examples/Helloworld`, `Examples/RouteGuide`
- Interop: `./scripts/run-python-to-lean.sh`, `./scripts/run-go-to-lean.sh`
