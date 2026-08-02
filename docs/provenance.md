# Provenance & IP diligence

**Reviewed:** 2026-08-02  
**Product:** lean-grpc (Riley Betts Ltd / rileybetts.ai)  
**Purpose:** Short paper trail for supply-chain / IP diligence. lean-grpc is an **independent implementation** of the published gRPC-over-HTTP/2 protocol, not a fork of grpc-go, grpc Java/C-core, or other official runtimes.

## What was read (normative protocol sources)

Wire behaviour was implemented from public protocol documentation, including:

- [gRPC over HTTP/2 (PROTOCOL-HTTP2)](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)
- [Official interop test descriptions](https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md) (behavioural cases)
- HTTP/2 ([RFC 9113](https://www.rfc-editor.org/rfc/rfc9113)) and HPACK ([RFC 7541](https://www.rfc-editor.org/rfc/rfc7541))
- Protocol Buffers encoding (public protobuf wire-format docs)

Upstream PROTOCOL-HTTP2 remains normative for the wire format. lean-grpc’s own mapping is documented in [protocol-mapping.md](protocol-mapping.md).

## Independent Lean stack (no copied runtime code)

The Lean libraries (`Bytes`, `Hpack`, `H2`, `Proto`, `Grpc`, examples that are lean-grpc-authored, codegen, native OpenSSL/zlib bridges authored for this repo) were written as a clean implementation of those specs.

**Confirmation:** no source code or substantial documentation text was copied from official gRPC runtime repositories (e.g. `grpc/grpc`, `grpc/grpc-go`) into those Lean / native modules. Apache-2.0 on those upstream projects covers *their* code; it is not required merely to implement the published protocol.

## Third-party Apache-2.0 materials in this repo

For **peer interop fixtures only**, this repository vendors official `grpc.testing` protocol buffers (and may generate stubs from them):

| Location | Origin |
|---|---|
| `python_interop/proto/*.proto` | gRPC authors (`grpc.testing`), Apache-2.0 |
| `rust_interop/proto/*.proto` | same |

Those files retain their upstream copyright and Apache-2.0 license headers. See [NOTICE](../NOTICE). They are **not** part of the public Lean consumer API.

## Trademark / naming

lean-grpc describes itself as an independent stack **compatible with** the gRPC-over-HTTP/2 protocol. It does not claim to be Google’s gRPC, an official Google product, or endorsed by Google.

## License of lean-grpc itself

SPDX **Apache-2.0** — [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
