# VaultGauntlet

A short, multi-act heist app that stress-tests lean-grpc against PROTOCOL-HTTP2 / library mapping expectations.

## Story

Break into a vault by enlisting, collecting streamed clues, depositing compressed key shards, and picking the lock over a bidi stream — then run wire-level probes (415, trailers-only, deadlines, RST→CANCELLED, status details).

## Acts

| Act | RPC | What it exercises |
|---|---|---|
| I | `Enlist` unary | Metadata + `-bin`, unary OK |
| II | `Clues` server-stream | Multiple length-prefixed responses |
| III | `DepositShards` client-stream | Gzip Compressed-Flag frames |
| IV | `PickLock` bidi | openStream send/recv + half-close |
| V | `Sabotage` unary | `grpc-status-details-bin` / `google.rpc.Status` |
| VI | Health `Check` | Standard health service |
| VII–XI | probes | HTTP 415, unimplemented trailers-only, zero timeout, RST cancel, user-agent |

## Run

```bash
./scripts/run-vault-gauntlet.sh
# or:
lake build vaultGauntletServer vaultGauntletClient
GRPC_PORT=50177 ./.lake/build/bin/vaultGauntletServer &
./.lake/build/bin/vaultGauntletClient 127.0.0.1 50177
```

Exit code `0` means every check passed.

## Spec verdict (latest run)

**ALL 16 CHECKS PASSED** against lean-grpc’s PROTOCOL-HTTP2 mapping for the surfaces exercised (unary/streaming/gzip, HTTP 415, trailers-only unimplemented, zero-timeout deadline, RST→CANCELLED, `grpc-status-details-bin`, health, user-agent).

While building this app we found and fixed a real stack bug: `Grpc.Stream.StreamReader.recv?` used the pure stored-deflate decoder, so **bidi/server-stream responses negotiated as gzip failed**. It now uses peer-compatible `Message.decodeOneIO`.
