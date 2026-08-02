# Security policy

## Supported versions

Security fixes are applied to the published tip (`main` / `development` as released). There is no long-term LTS train yet.

**Supported version:** the latest **tagged** release (e.g. `v0.5.0`). Maintainers create tags manually — see [docs/packaging.md](docs/packaging.md). Prefer GitHub Security Advisories for private reports when enabled.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security-sensitive reports.

1. Email **security@rileybetts.ai** with subject prefix `[SECURITY] lean-grpc`.
2. Include: affected revision, impact, reproduction steps, and any proposed fix.
3. Allow a reasonable window for a patch or advisory before public disclosure.

You may also open a private [GitHub Security Advisory](https://github.com/RileyBetts/lean-grpc/security/advisories) on the repository when that channel is enabled.

## Security-relevant surfaces

| Area | Notes |
|---|---|
| TLS / mTLS | OpenSSL via `native/tls_ffi.c`; empty `caPath` uses the **system trust store** + hostname verify. Set `Tls.Config.insecureSkipVerify` (stderr WARN) only for fixtures |
| ADC token HTTPS | `httpsPost` verifies peer+hostname by default; env redirects / cleartext require `LEAN_GRPC_ALLOW_ADC_OVERRIDE=1` |
| h2c | Cleartext — bind to localhost or mesh-only networks in production |
| `LEAN_GRPC_TLS_INSECURE_FALLBACK=1` | Disables TLS — never in production |
| Other env overrides | `LEAN_GRPC_TOKEN_*`, `LEAN_GRPC_GCE_METADATA`, `LEAN_GRPC_RESOLVE_ADDRS` (+ `ALLOW_*`), `LEAN_GRPC_XDS_INSECURE`, `LEAN_GRPC_ZLIB_HELPER` — admin/test-only |
| Compression | Decompressed size capped by `maxMsgSize` (default 4 MiB) in Message/Server paths and native zlib `max_out` |
| xDS / ADS / SDS | Cleartext ADS/grpclb only with `LEAN_GRPC_XDS_INSECURE=1`; SDS paths must sit under `LEAN_GRPC_SDS_ROOT` (default `/var/run/secrets`) |
| Message size limits | Configure `maxSendMsgSize` / `maxRecvMsgSize` for hostile peers |
| Reflection / channelz / binary log | Expose internals / may capture metadata — demos gate reflection/channelz behind `LEAN_GRPC_DEMO_OPS=1`; BinaryLog redacts `authorization` |
| Codegen plugin | Hostile `.proto` / plugin stdin names are allowlisted (`[A-Za-z_][A-Za-z0-9_]*`) |
| Native FFI | Report memory bugs with ASAN notes; CI runs `scripts/security-asan.sh` |

Full audit + remediation status: [docs/security-review-2026-08.md](docs/security-review-2026-08.md). Hosted security summary: [rileybetts.ai/oss/lean-grpc/security](https://rileybetts.ai/oss/lean-grpc/security).

## Out of scope / known limitations

- **ALTS** and **GCE channel credentials** are not implemented (allowlisted).
- HTTP CONNECT proxying is not implemented.
- Huffman decode-trie rewrite and full xDS bootstrap JSON rewrite remain follow-ups (mitigated by header-list caps / existing scrape).
- This is a young stack: prefer defense in depth (network policy, sidecar TLS, authn/z at the app layer) for high-risk deployments.
- Formal Lean proofs of the wire stack are not yet present (see [ROADMAP.md](ROADMAP.md)); OpenSSL and zlib remain a trusted TCB.

## Acknowledgments

We appreciate responsible disclosure and will credit reporters who want acknowledgment once a fix is released.
