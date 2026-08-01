# SignalWeave

Go client → Lean [lean-grpc](../..) stress demo (companion to [VaultGauntlet](../VaultGauntlet/README.md) and [MirrorForge](../MirrorForge/README.md)).

Radio / spectrum theme: a Go station dials a Lean exchange over h2c, tunes a band, scans, uplinks compressed bursts, and completes a bidi handshake — then probes status codes, deadlines, and health.

## Acts

| Act | RPC | What it exercises |
|---|---|---|
| I | `Tune` unary | Protobuf wire + custom metadata + OK |
| II | `Tune` empty station | `INVALID_ARGUMENT` |
| III | `Tune` low kHz | `OUT_OF_RANGE` |
| IV | `Spectrum` server-stream | Multi-message length-prefixed responses |
| V | `Uplink` client-stream | Gzip Compressed-Flag frames + XOR fold |
| VI | `Handshake` bidi | SYN/ACK → LOCK |
| VII | `Blackout` unary | `INTERNAL` |
| VIII | `SlowTune` | Client deadline → `DEADLINE_EXCEEDED` |
| IX | Health `Check` | Standard `grpc.health.v1` SERVING |
| X | `Tune` + UA | `grpc-go` user-agent + outbound metadata |

## Run

```bash
./scripts/run-signal-weave.sh
# or:
lake build signalWeaveServer
GRPC_PORT=50301 ./.lake/build/bin/signalWeaveServer &
cd Examples/SignalWeave/go && go run . 127.0.0.1 50301
```

Exit code `0` means every check passed.

Wire codecs live in `Protocol.lean` (Lean) and `go/wire.go` (Go); no `.proto` / protoc required.

## Spec verdict (latest run)

**ALL 10 CHECKS PASSED** (Go `grpc-go` client → Lean SignalWeave server): unary + status codes, server/client/bidi streams, gzip uplink, deadline, health.

While building this demo we fixed a real stack bug: bidi handlers were re-invoked with an empty payload on grpc-go’s trailers-only half-close (`DATA` length 0 + `END_STREAM`), which wiped incremental handshake/batch state and surfaced a spurious `FAILED_PRECONDITION`. Empty half-close now finalizes with trailers-only `OK`.
