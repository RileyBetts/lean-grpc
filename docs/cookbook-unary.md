<!--
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
-->

# Cookbook: typed unary RPC

Preferred app path: generate typed stubs, then register/call without hand-rolled `ByteArray` codecs.

## Generate stubs

```bash
lake build protocGenLean4Grpc
./scripts/gen-helloworld.sh
# → Examples/Helloworld/Generated.lean
```

Or with a real `protoc`:

```bash
protoc --plugin=protoc-gen-lean4-grpc=./.lake/build/bin/protoc-gen-lean4-grpc \
  --lean4_out=. -I examples examples/helloworld.proto
```

## Server

```lean
import Grpc
import Examples.Helloworld.Generated

def main : IO Unit := do
  let mut s := Grpc.Server.empty
  s := helloworld.registerGreeterSayHello s fun req => do
    pure ({ message := s!"Hello, {req.name}" }, .ok)
  Grpc.Server.serveH2c s { host := "127.0.0.1", port := 50051 }
```

### With `ServerCallContext` (mTLS peer identity / inbound metadata)

Generated stubs also emit `register*WithContext`:

```lean
s := helloworld.registerGreeterSayHelloWithContext s fun ctx req => do
  match ctx.peerIdentity with
  | none => pure ({ message := "" }, .unauthenticated "mtls_required")
  | some id =>
      pure ({ message := s!"Hello, {req.name} (from {id.commonName})" }, .ok)
```

See [Cookbook: interceptors & auth](cookbook-interceptors.md) for mTLS `serveTls` and MirrorForge.

## Client

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

## Deadlines and metadata

```lean
let md := Grpc.Metadata.empty
  |> (Grpc.Metadata.add · "x-request-id" "abc")
let res ← Grpc.Channel.unary ch "helloworld.Greeter" "SayHello"
  (helloworld.HelloRequest.encode { name := "Lean" }) md (some "2S")
```

Timeout strings: `H` / `M` / `S` / `m` / `u` / `n` (gRPC duration grammar).

## See also

- Working example: `Examples/Helloworld/`
- [Cookbook: streaming](cookbook-streaming.md)
- [Cookbook: interceptors & auth](cookbook-interceptors.md)
