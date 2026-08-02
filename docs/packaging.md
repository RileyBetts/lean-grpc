# Packaging and open-source distribution

How lean-grpc is structured for Lake consumers and what maintainers do to publish.

## Layout (keep the monorepo)

lean-grpc is a single Lake package. Do not split libraries into separate repos for packaging.

| Path / target | Role | Consumer API? |
|---|---|---|
| `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` | Library stack | Yes |
| `LeanGrpc.lean` | Umbrella import | Yes |
| `Proofs` | Compile-time theorems (CI only; not consumer API) | No |
| `native/` + OpenSSL link args | TLS FFI (`tls_ffi.o`, `-lssl -lcrypto`) | Required for TLS / ADC |
| `Tests/`, `Bench/`, `Examples/`, `scripts/`, `python_interop/`, `rust_interop/` | Dev / CI / demos | No |
| `lakefile.lean`, `lake-manifest.json`, `lean-toolchain` | Lake package root | Required for Reservoir |

```
lean-grpc/
  lakefile.lean
  lake-manifest.json
  lean-toolchain
  LeanGrpc.lean / Grpc.lean / H2.lean / …
  Bytes/ Hpack/ H2/ Proto/ Grpc/ Proofs/ native/
  Examples/ Tests/ Bench/ scripts/ docs/
  LICENSE README CONTRIBUTING SECURITY CHANGELOG
```

## Registries

| Channel | Use |
|---|---|
| **Reservoir** | Primary Lean package index ([inclusion criteria](https://reservoir.lean-lang.org/inclusion-criteria)) |
| **Lake git require + tags** | Immediate consume path: pin `@ "vX.Y.Z"` |
| npm / PyPI / Maven / crates | Not used. Optional later: GitHub Release binaries for `protoc-gen-lean4-grpc` only |

## License

**Apache-2.0** (SPDX). Matches Lean 4, mathlib4, and typical Reservoir packages; fits a TLS/networking stack (explicit patent grant). Confirm GitHub’s license badge shows Apache-2.0 on the public repository; adjust `LICENSE` / `NOTICE` only if detection fails.

**Provenance:** lean-grpc is an independent implementation of the published gRPC-over-HTTP/2 protocol (not a fork of official runtimes). Peer fixtures under `python_interop/proto/` and `rust_interop/proto/` retain Apache-2.0 gRPC-authors headers; see [NOTICE](../NOTICE) and [provenance.md](provenance.md).

## Consumer contract

**Public libraries:** `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (umbrella `LeanGrpc`). Tests, examples, and `Proofs` are not consumer API.

**System dependencies:**

| Platform | Packages |
|---|---|
| Debian / Ubuntu | `libssl-dev`, `pkg-config` |
| macOS (Homebrew) | `openssl` (or `openssl@3`), `pkg-config` |
| No sudo / missing headers | `./scripts/fetch-openssl-headers.sh` |

Link flags come from the `Grpc` library (`-lssl -lcrypto`). The OpenSSL FFI object (`tls_ffi.o`) is built via Lake. Peer gzip uses process helpers (`LEAN_GRPC_ZLIB_HELPER` after `./scripts/build_native.sh`) or system `gzip` / a stored-deflate fallback — `zlib_bridge.o` is **not** linked into Lean. Optional: `zlib1g-dev` / Homebrew `zlib` only if you build the native zlib helper yourself.

**macOS note:** Lean’s linker may not find Homebrew OpenSSL unless library search paths are set:

```bash
export LIBRARY_PATH="$(brew --prefix openssl@3)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
lake build
```

**Depend via Lake (git tag):**

```lean
require «lean-grpc» from git
  "https://github.com/RileyBetts/lean-grpc.git" @ "v1.0.0"
```

Then `import Grpc` (and `Proto` if using bundled codecs).

**Reservoir** (after indexing):

```lean
require «lean-grpc»   -- once listed on reservoir.lean-lang.org
```

Package version in-tree is **1.0.0** (`lakefile.lean`, `Grpc.version`). Hosted docs: [rileybetts.ai/oss/lean-grpc](https://rileybetts.ai/oss/lean-grpc). Creating the git tag on origin is a separate maintainer step (below).

## Maintainer release checklist

Documented only — do **not** automate tagging from CI or agent runs.

1. Merge packaging / feature work → `development`, then promote to `main` when ready to publish.
2. Confirm the repository is **public** and GitHub license detection shows **Apache-2.0**.
3. Enable GitHub Security Advisories / private vulnerability reporting if available.
4. Obtain **≥2 GitHub stars** ([Reservoir inclusion criteria](https://reservoir.lean-lang.org/inclusion-criteria)).
5. **Manual version tagging (maintainer only):** on `main`, when you choose to publish:

   ```bash
   git tag -a v1.0.0 -m "lean-grpc 1.0.0"
   git push origin v1.0.0
   ```

   Agents and CI must not create or push tags.
6. Wait for Reservoir’s daily crawl (typically within a few days). Verify:
   - Package appears at `https://reservoir.lean-lang.org/` (search `lean-grpc` / `RileyBetts`).
   - Build status and homepage link (`https://rileybetts.ai/oss/lean-grpc`) look correct.
   - Update README / site copy to prefer bare `require «lean-grpc»` once the page is live.
7. Optional later (manual): GitHub Release attaching `protoc-gen-lean4-grpc` binaries only.
8. Set repo topics (`lean4`, `grpc`, `http2`, …) and keep the description aligned with `lakefile.lean`.
9. Keep curated website pages in sync when published guides change (see [website-sync.md](website-sync.md)).

## Branching

- `main` — stable releases / published tip  
- `development` — integration  
- `feature/…` — branch from `development`

See also [CONTRIBUTING.md](../CONTRIBUTING.md) and [CHANGELOG.md](../CHANGELOG.md).
