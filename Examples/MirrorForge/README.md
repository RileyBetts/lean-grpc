# MirrorForge

A second Lean↔Lean stress demo (companion to [VaultGauntlet](../VaultGauntlet/README.md)).

Two forge processes (`alpha` / `beta`) sit behind a round-robin channel. The client walks ops, LB, retry, hedging, and observability surfaces that VaultGauntlet does not emphasize.

## Acts

| Act | What it exercises |
|---|---|
| Stamp ×2 + interceptor | Unary + client logging interceptor + forge mark |
| Round-robin | `LEAN_GRPC_RESOLVE_ADDRS` + `loadBalancingPolicy=round_robin` → different `forgeId`s |
| Auth reject | Body token gate → `UNAUTHENTICATED` |
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
