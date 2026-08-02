# lean-grpc documentation

User and contributor docs for the Lean 4 gRPC stack.

| Doc | Audience |
|---|---|
| [Getting started](getting-started.md) | First typed unary server/client, TLS, Lake dependency |
| [Cookbook: typed unary](cookbook-unary.md) | Generated stubs, deadlines, metadata |
| [Cookbook: streaming](cookbook-streaming.md) | `serverStream` / `clientStream` / `bidiStream` / `openStream` |
| [Cookbook: interceptors / auth / mTLS](cookbook-interceptors.md) | Logging chain, bearer tokens, TLS |
| [Architecture](architecture.md) | Layering, data flow, process model |
| [API reference](api-reference.md) | Primary `Grpc` / `H2` / `Proto` surfaces |
| [Protocol mapping](protocol-mapping.md) | How lean-grpc maps onto gRPC-over-HTTP/2 |
| [Conformance](conformance.md) | Scorecard, compliance estimates, interop matrix, allowlists |
| [TLS / Envoy](tls-envoy.md) | In-process OpenSSL and optional sidecars |
| [CONTRIBUTING](../CONTRIBUTING.md) | Dev setup, tests, PR expectations |
| [SECURITY](../SECURITY.md) | Vulnerability reporting |
| [VaultGauntlet example](../Examples/VaultGauntlet/README.md) | Multi-act heist stress app + wire probes (Lean↔Lean) |
| [MirrorForge example](../Examples/MirrorForge/README.md) | Dual-forge RR/retry/ops stress app (Lean↔Lean) |
| [SignalWeave example](../Examples/SignalWeave/README.md) | Go client → Lean spectrum-exchange stress demo |
| [Framing matrix](../Tests/FramingMatrix/README.md) | Clinical peer-framing gate (Lean↔Lean + Go→Lean) |
| [Python interop](../python_interop/README.md) | Official `grpc.testing` peer (Python ↔ Lean) |
| [Rust interop](../rust_interop/README.md) | Official `grpc.testing` peer (Rust/tonic ↔ Lean) |

Official external specs lean-grpc targets:

- [gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)
- [Interop test descriptions](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md)
- [HTTP/2](https://httpwg.org/specs/rfc9113.html) (validated via [h2spec](https://github.com/summerwind/h2spec))
