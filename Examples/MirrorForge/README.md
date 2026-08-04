# MirrorForge

A second Lean↔Lean stress demo (companion to [VaultGauntlet](../VaultGauntlet/README.md)).

Two forge processes (`alpha` / `beta`) sit behind a round-robin channel. The client walks ops, LB, retry, hedging, and observability surfaces that VaultGauntlet does not emphasize.

## Acts

| Act | What it exercises |
|---|---|
| Stamp ×2 + interceptor | Unary + client logging interceptor + forge mark; **Bearer metadata** (body token fallback) via `registerUnaryWithContext` |
| Round-robin | `LEAN_GRPC_RESOLVE_ADDRS` + `loadBalancingPolicy=round_robin` → different `forgeId`s |
| Auth reject | Missing/wrong credentials → `UNAUTHENTICATED` |
| Quench + retry | First `UNAVAILABLE`, client `retryPolicy` recovers |
| Health Check/Watch | Standard health service |
| Reflection v1alpha + v1 | `list_services` includes forge + health |
| Channelz | Non-zero call counters |
| Binary log | 5-event unary sequence |
| Stats | Registry snapshot |
| ORCA | OOB `StreamCoreMetrics` + load field in Stamp reply |
| Hedge config + SlowStamp | `hedgingPolicy` JSON parses; slow unary still OK |

## Run

```bash
./scripts/run-mirror-forge.sh
```

Exit `0` = all checks passed.

## Optional TLS / mTLS

Default listen is h2c. To exercise 1.1.0 peer identity:

```bash
# Server (each forge):
TLS_CERT=certs/server.crt TLS_KEY=certs/server.key TLS_CLIENT_CA=certs/ca.crt \
  FORGE_ID=alpha GRPC_PORT=50201 ./.lake/build/bin/mirrorForgeServer

# Client:
TLS_CA=certs/ca.crt TLS_CERT=certs/client.crt TLS_KEY=certs/client.key \
  TLS_SERVER_NAME=127.0.0.1 \
  ./.lake/build/bin/mirrorForgeClient 127.0.0.1 50201 50202
```

With `TLS_CLIENT_CA` set, Stamp runs `requirePeerIdentity` and embeds the peer CN in the stamp mark (`{forgeId}:{cn}:{billet}`).
