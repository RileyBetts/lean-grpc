# TLS + ALPN for lean-grpc

Pure-Lean TLS is **Phase 7** and not implemented yet.

## Recommended production pattern

1. Run Lean gRPC with **h2c** on `127.0.0.1` only (e.g. port `50051`).
2. Put Envoy / Caddy / nginx in front with TLS and ALPN `h2`.
3. Proxy HTTP/2 to the local Lean listener.

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
          http_filters:
          - name: envoy.filters.http.router
  clusters:
  - name: lean_grpc
    type: STATIC
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options: {}
    load_assignment:
      cluster_name: lean_grpc
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 50051 }
```

When a Lean TLS stack with ALPN appears, wire `Grpc.Tls.connectH2` / `serveH2` without changing application handlers.
