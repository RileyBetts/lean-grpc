# TLS + ALPN for lean-grpc

## Default: in-process OpenSSL

`Grpc.Tls.connectH2` / `serveH2` use the native OpenSSL bridge (`native/tls_ffi.c`) for ALPN `h2`.
Empty/`none` `caPath` uses the **system trust store** with hostname verification.
Use `insecureSkipVerify := true` only for local fixtures (prints a stderr warning).

```lean
let ch ← Grpc.Channel.dial "api.example.com:443" {
  channel := .tls {
    caPath := some "/etc/ssl/certs/ca.pem"  -- or none → system CAs
    serverName := some "api.example.com"
  }
}
```

Server with certs:

```lean
Grpc.Tls.serveH2 {
  certPath := some "server.pem"
  keyPath := some "server.key"
} h2cfg handler
```

Interop: `./scripts/interop-tls-go-lean.sh` (Lean client → Go TLS server, **no** `LEAN_GRPC_TLS_PROXY`).

Build needs OpenSSL headers (`libssl-dev`, or `./scripts/fetch-openssl-headers.sh` when headers are missing).

## Optional sidecar (Envoy / Caddy / `tls_proxy`)

Still supported:

1. Run Lean gRPC with **h2c** on `127.0.0.1` only.
2. Put Envoy / Caddy / `native/tls_proxy` in front with TLS and ALPN `h2`.
3. Or set `LEAN_GRPC_TLS_PROXY=host:port` so the Lean client dials h2c to the local terminator.

### Envoy sketch

```yaml
static_resources:
  listeners:
  - name: grpc_tls
    address: { socket_address: { address: 0.0.0.0, port_value: 443 } }
    filter_chains:
    - transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          common_tls_context:
            alpn_protocols: ["h2"]
            tls_certificates:
            - certificate_chain: { filename: cert.pem }
              private_key: { filename: key.pem }
      filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          codec_type: HTTP2
          http2_protocol_options: {}
          route_config:
            virtual_hosts:
            - name: grpc
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route: { cluster: lean_grpc }
```

## Dev fallback

`LEAN_GRPC_TLS_INSECURE_FALLBACK=1` forces plain h2c (never use in production).
