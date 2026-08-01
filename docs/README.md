# lean-grpc documentation

User and contributor docs for the Lean 4 gRPC stack.

| Doc | Audience |
|---|---|
| [Getting started](getting-started.md) | First unary server/client, TLS, Lake dependency |
| [Architecture](architecture.md) | Layering, data flow, process model |
| [API reference](api-reference.md) | Primary `Grpc` / `H2` / `Proto` surfaces |
| [Protocol mapping](protocol-mapping.md) | How lean-grpc maps onto gRPC-over-HTTP/2 |
| [Conformance](conformance.md) | Scorecard, interop matrix, allowlists |
| [TLS / Envoy](tls-envoy.md) | In-process OpenSSL and optional sidecars |
| [CONTRIBUTING](../CONTRIBUTING.md) | Dev setup, tests, PR expectations |
| [SECURITY](../SECURITY.md) | Vulnerability reporting |
| [VaultGauntlet example](../Examples/VaultGauntlet/README.md) | Multi-act heist stress app + wire probes (Lean↔Lean) |
| [MirrorForge example](../Examples/MirrorForge/README.md) | Dual-forge RR/retry/ops stress app (Lean↔Lean) |

Official external specs lean-grpc targets:

- [gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)
- [Interop test descriptions](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md)
- [HTTP/2](https://httpwg.org/specs/rfc9113.html) (validated via [h2spec](https://github.com/summerwind/h2spec))
