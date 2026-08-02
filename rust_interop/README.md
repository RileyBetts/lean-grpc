# Rust interop helpers

Uses [tonic](https://github.com/hyperium/tonic) + official `grpc.testing` protos to exercise lean-grpc from Rust (same case matrix as `python_interop/`).

```bash
# Rust client → Lean server
./scripts/run-rust-to-lean.sh

# Lean client → Rust server
GRPC_PORT=10001 ./scripts/interop-lean-rust.sh
```

Requires a Rust toolchain (`cargo` / `rustc`). Proto codegen uses a vendored `protoc` via `protoc-bin-vendored` (no system `protoc` needed).
