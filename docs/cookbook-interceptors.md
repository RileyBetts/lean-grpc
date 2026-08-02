<!--
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
-->

# Cookbook: interceptors, auth, TLS / mTLS

## Logging interceptor

```lean
let sink ← IO.mkRef (#[] : Array String)
let chain : Array Grpc.Interceptor.ServerUnary := #[Grpc.Interceptor.loggingServer sink]
let mut s := Grpc.Server.empty
s := Grpc.Interceptor.registerUnary s "demo.Svc" "Ping" chain fun req => do
  pure (req, .ok)
```

Client side:

```lean
let res ← Grpc.Interceptor.callUnary ch "demo.Svc" "Ping"
  #[Grpc.Interceptor.loggingClient sink] reqBytes
```

## Bearer token (call credentials)

`ClientUnary` only wraps the request body, so attach auth metadata on the call (or via dial call-creds):

```lean
let md := Grpc.Interceptor.bearerMetadata "my-token"
let res ← Grpc.Channel.unary ch "svc" "Method" req md

-- Or dial-wide:
let ch ← Grpc.Channel.dial "127.0.0.1:50051" {
  call := some (Grpc.Credentials.CallCredentials.accessToken "my-token")
}
```

## Deadlines

```lean
-- 100 milliseconds
let res ← Grpc.Channel.unary ch "svc" "Slow" req {} (some "100m")
-- 2 seconds
let res ← Grpc.Channel.unary ch "svc" "Slow" req {} (some "2S")
```

On deadline expiry the client maps to `DEADLINE_EXCEEDED` (and may RST the stream).

## TLS dial

```lean
let ch ← Grpc.Channel.dial "api.example.com:443" {
  channel := .tls {
    caPath := some "/etc/ssl/certs/ca-certificates.crt"
    serverName := some "api.example.com"
  }
}
```

## mTLS

Client presents a certificate; server requires and verifies one:

```lean
-- Client
let ch ← Grpc.Channel.dial "localhost:50051" {
  channel := .tls {
    caPath := some "certs/ca.pem"
    certPath := some "certs/client.pem"
    keyPath := some "certs/client.key"
    serverName := some "localhost"
  }
}

-- Server
Grpc.Server.serveTls s {
  certPath := some "certs/server.pem"
  keyPath := some "certs/server.key"
  clientCaPath := some "certs/ca.pem"
} { host := "127.0.0.1", port := 50051 }
```

End-to-end coverage: `tlsLoopback` (plain TLS, reject without client cert, accept with client cert).

## See also

- [TLS / Envoy](tls-envoy.md)
- `Tests/OpsSmoke.lean` — interceptor + health/reflection/channelz smoke
- `Tests/TlsLoopback.lean` — mTLS loopback
