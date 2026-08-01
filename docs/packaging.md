# Packaging and open-source distribution

How lean-grpc is structured for Lake consumers and what maintainers do to publish.

## Layout (keep the monorepo)

lean-grpc is a single Lake package. Do not split libraries into separate repos for packaging.

| Path / target | Role | Consumer API? |
|---|---|---|
| `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` | Library stack | Yes |
| `LeanGrpc.lean` | Umbrella import | Yes |
| `native/` + OpenSSL/zlib link args | TLS / gzip FFI | Required for full features |
| `Tests/`, `Bench/`, `Examples/`, `scripts/`, `python_interop/` | Dev / CI / demos | No |
| `lakefile.lean`, `lake-manifest.json`, `lean-toolchain` | Lake package root | Required for Reservoir |

```
lean-grpc/
  lakefile.lean
  lake-manifest.json
  lean-toolchain
  LeanGrpc.lean / Grpc.lean / H2.lean / …
  Bytes/ Hpack/ H2/ Proto/ Grpc/ native/
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

**Apache-2.0** (SPDX). Matches Lean 4, mathlib4, and typical Reservoir packages; fits a TLS/networking stack (explicit patent grant).

While the repository is private, GitHub may report license as `NOASSERTION`. After making the repo public, confirm the license badge shows Apache-2.0; adjust `LICENSE` only if detection still fails.

## Consumer contract

**Public libraries:** `Bytes`, `Hpack`, `H2`, `Proto`, `Grpc` (umbrella `LeanGrpc`). Tests and examples are not API.

**System dependencies:**

| Platform | Packages |
|---|---|
| Debian / Ubuntu | `libssl-dev`, `pkg-config`, `zlib1g-dev` |
| macOS (Homebrew) | `openssl` (or `openssl@3`), `pkg-config` |
| No sudo / missing headers | `./scripts/fetch-openssl-headers.sh` |

Link flags come from the package (`-lssl -lcrypto -lz`). Native objects are built via Lake (`tls_ffi.o`, `zlib_bridge.o`). Optional helpers: `./scripts/build_native.sh`.

**macOS note:** Lean’s linker may not find the system `libz` / Homebrew OpenSSL unless library search paths are set:

```bash
export LIBRARY_PATH="$(xcrun --show-sdk-path)/usr/lib:$(brew --prefix openssl@3)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
lake build
```

**Depend via Lake (git tag):**

```lean
require «lean-grpc» from git
  "https://github.com/RileyBetts/lean-grpc.git" @ "v0.5.0"
```

Then `import Grpc` (and `Proto` if using bundled codecs).

**Reservoir** (after indexing):

```lean
require «lean-grpc»   -- once listed on reservoir.lean-lang.org
```

Package version in-tree is **0.5.0** (`lakefile.lean`, `Grpc.version`). Creating the git tag on origin is a separate maintainer step (below).

## Maintainer release checklist

Documented only — do **not** automate tagging from CI or agent runs.

1. Merge packaging / feature work → `development`, then promote to `main` when ready to publish.
2. **Make the repository public** (Settings → Change visibility).
3. Confirm GitHub license detection shows **Apache-2.0**.
4. Enable GitHub Security Advisories / private vulnerability reporting if available.
5. Obtain **≥2 GitHub stars** (Reservoir gate).
6. **Manual version tagging (maintainer only):** on `main`, when you choose to publish:

   ```bash
   git tag -a v0.5.0 -m "lean-grpc 0.5.0"
   git push origin v0.5.0
   ```

   Agents and CI must not create or push tags.
7. Wait for Reservoir’s daily crawl; verify the package page; update the README Reservoir require once live.
8. Optional later (manual): GitHub Release attaching `protoc-gen-lean4-grpc` binaries only.
9. Set repo topics (`lean4`, `grpc`, `http2`, …) and keep the description aligned with `lakefile.lean`.

## Branching

- `main` — stable releases / published tip  
- `development` — integration  
- `feature/…` — branch from `development`

See also [CONTRIBUTING.md](../CONTRIBUTING.md) and [CHANGELOG.md](../CHANGELOG.md).
