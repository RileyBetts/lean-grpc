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

## mTLS → read `ctx.peerIdentity` in the handler

Client presents a certificate; server requires and verifies one, then exposes the
**verified** peer identity to unary handlers via `ServerCallContext`:

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
let mut s := Grpc.Server.empty
s := Grpc.Server.registerWithContext s "demo.Svc" "Ping" fun ctx req => do
  match ctx.peerIdentity with
  | none =>
      -- Under mTLS (`clientCaPath` set) this should be unreachable after a
      -- successful handshake; treat as miswire / UNAUTHENTICATED.
      pure (ByteArray.empty, .unauthenticated "mtls_required")
  | some id =>
      -- Map id.uriSans / id.commonName → principal via local policy.
      -- Subject DN is OpenSSL RFC 2253 form.
      pure (req, .ok)

-- Optional interceptor that fails closed when mTLS was configured but identity is missing:
s := Grpc.Interceptor.registerUnaryWithContext s "demo.Svc" "Secure"
  #[Grpc.Interceptor.requirePeerIdentity] fun ctx req => do
    pure (req, .ok)

Grpc.Server.serveTls s {
  certPath := some "certs/server.pem"
  keyPath := some "certs/server.key"
  clientCaPath := some "certs/ca.pem"
} { host := "127.0.0.1", port := 50051 }
```

**Do not** treat inbound metadata such as `x-client-subject`, `x-forwarded-client-cert`,
or a self-declared `principalId` in the request body as AuthN. Those values are
attacker-controlled unless you terminate TLS at a **trusted** proxy and document a
separate trusted-proxy identity mode (not provided by lean-grpc today). Identity
fields are only as trustworthy as the `clientCaPath` private CA / PKI.

End-to-end coverage: `tlsLoopback` (plain TLS, reject without client cert, accept
with client cert, dual-cert identity binding, metadata non-forgery, h2c → `none`,
accept-loop survival after failed handshake).

Working example: `Examples/MirrorForge/` — `Stamp` uses `registerUnaryWithContext`
(Bearer metadata preferred, body token fallback). Set `TLS_CERT`/`TLS_KEY`/
`TLS_CLIENT_CA` on the server and `TLS_CA` (+ client cert) on the client for mTLS;
see `Examples/MirrorForge/README.md`.

Streaming handlers do not yet receive `ServerCallContext` (follow-on).

## See also

- [TLS / Envoy](tls-envoy.md)
- `Tests/OpsSmoke.lean` — interceptor + health/reflection/channelz smoke
- `Tests/TlsLoopback.lean` — mTLS + peer-identity loopback
