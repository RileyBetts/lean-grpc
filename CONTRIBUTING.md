# Contributing to lean-grpc

Thanks for helping improve the Lean 4 gRPC stack. This document covers local setup, testing, and pull request expectations.

## Development setup

1. Install [elan](https://github.com/leanprover/elan) / Lean 4 matching `lean-toolchain` (4.32.x).
2. Install OpenSSL headers (`libssl-dev` / `pkg-config` on Debian/Ubuntu; Homebrew `openssl` + `pkg-config` on macOS) or run `./scripts/fetch-openssl-headers.sh`.
3. Optional: Go 1.24+ and Python 3.12+ for interop matrices; `zlib1g-dev` (or Homebrew `zlib`) for native gzip helper.

```bash
./scripts/fetch-openssl-headers.sh   # no-op when system headers exist
lake build
./scripts/build_native.sh            # zlib_helper (+ optional tls_proxy)
```

## Branching

- `main` — stable releases / published tip  
- `development` — integration branch  
- Feature work: branch from `development` (e.g. `feature/…`)

Release / Reservoir checklist (tagging is **manual**): [docs/packaging.md](docs/packaging.md).

## Tests to run before a PR

**Minimum (every change):**

```bash
lake build bytesTests hpackTests h2Tests grpcTests trailersLoopback
./.lake/build/bin/bytesTests
./.lake/build/bin/hpackTests
./.lake/build/bin/h2Tests
./.lake/build/bin/grpcTests
./.lake/build/bin/trailersLoopback
```

**When touching wire / H2:**

```bash
./scripts/h2spec.sh
```

**When touching gRPC app surface / interop:**

```bash
# Lean↔Lean core cases (see CI job for full list)
lake build interopServer interopClient
./.lake/build/bin/interopServer &
./.lake/build/bin/interopClient 127.0.0.1 10000 empty_unary
# …
./scripts/run-go-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-go-lean.sh
./scripts/run-python-to-lean.sh
GRPC_PORT=10001 ./scripts/interop-lean-python.sh
```

**When touching TLS / ADC / xDS / codegen / soak:**

```bash
./scripts/interop-tls-go-lean.sh
lake build tlsLoopback && ./.lake/build/bin/tlsLoopback
./scripts/run-adc-smoke.sh
./scripts/run-xds-ads-smoke.sh
./scripts/run-codegen-fixture.sh
./scripts/run-soak.sh
```

CI (`.github/workflows/ci.yml`) is the source of truth for the hard gate set.

## Coding guidelines

- Match existing Lean style and Apache-2.0 copyright headers on new files.
- Prefer small, focused PRs (one phase / one surface).
- Update [docs/conformance.md](docs/conformance.md) when changing tested vs allowlisted behavior.
- Do not claim live-GCP coverage for ALTS / GCE channel credentials; keep them in `Grpc.Gcp.deferredCases`.
- Avoid secret materials in the repo (certs in tests should be generated at runtime, e.g. `tlsLoopback`).

## Documentation

User docs live under [`docs/`](docs/README.md). When you add a public API or change wire behavior, update:

- `docs/api-reference.md` and/or `docs/protocol-mapping.md`
- `docs/conformance.md` scorecard / checklist
- `README.md` only for high-level status or top-level commands

## Pull requests

1. Clear description of *why* and how to test.
2. Green CI on the PR branch.
3. No unrelated refactors.
4. Do not force-push `main` / `development` unless maintainers ask.

## License

By contributing, you agree your contributions are licensed under the Apache License 2.0 (`LICENSE`).
