# Security policy

## Supported versions

Security fixes are applied to the published tip (`main` / `development` as released). There is no long-term LTS train yet.

**Supported version:** the latest **tagged** release (e.g. `v0.5.0`) once tags exist; until then, use a recent commit from `main`. Maintainers create tags manually — see [docs/packaging.md](docs/packaging.md). After the repository is public, prefer GitHub Security Advisories for private reports when enabled.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security-sensitive reports.

1. Email the maintainer listed in the repository owner profile / commit history for [RileyBetts/lean-grpc](https://github.com/RileyBetts/lean-grpc), with subject prefix `[SECURITY] lean-grpc`.
2. Include: affected revision, impact, reproduction steps, and any proposed fix.
3. Allow a reasonable window for a patch or advisory before public disclosure.

If private contact fails, open a GitHub Security Advisory on the repository (if enabled) or a minimal private maintainer contact request without exploit details.

## Security-relevant surfaces

| Area | Notes |
|---|---|
| TLS / mTLS | OpenSSL via `native/tls_ffi.c`; keep system OpenSSL updated |
| h2c | Cleartext — bind to localhost or mesh-only networks in production |
| `LEAN_GRPC_TLS_INSECURE_FALLBACK=1` | Disables TLS — never in production |
| ADC / tokens | Treat service-account JSON and metadata tokens as secrets; CI uses mocks |
| Message size limits | Defaults to 4 MiB; configure `maxSendMsgSize` / `maxRecvMsgSize` for hostile peers |
| Reflection / channelz | Expose process internals — disable or firewall on public endpoints |
| Native FFI | Bugs in `tls_ffi` / zlib bridge can be memory-unsafe; report with ASAN notes if available |

## Out of scope / known limitations

- **ALTS** and **GCE channel credentials** are not implemented (allowlisted).
- HTTP CONNECT proxying is not implemented.
- This is a young stack: prefer defense in depth (network policy, sidecar TLS, authn/z at the app layer) for high-risk deployments.

## Acknowledgments

We appreciate responsible disclosure and will credit reporters who want acknowledgment once a fix is released.
