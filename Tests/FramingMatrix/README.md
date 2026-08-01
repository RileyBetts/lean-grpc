# Framing matrix

Clinical peer-framing gate (companion to VaultGauntlet / MirrorForge / SignalWeave).

Exercises the bug classes those demos found:

| Case | Surface |
|---|---|
| Unary identity + gzip | Message framing |
| FanOut server-stream (± accept gzip) | Multi-frame responses + `decodeAllIO` |
| Collect client-stream gzip | Compressed-Flag request frames |
| Relay bidi + empty half-close | Empty `DATA+END_STREAM` after incremental replies |
| SlowEcho deadline | `DEADLINE_EXCEEDED` |
| RST / cancel | `CANCELLED` / context cancel |
| Bad content-type | HTTP 415 |

## Run

```bash
./scripts/run-framing-matrix.sh
# or all stress gates:
./scripts/run-stress-demos.sh
```

Default port: `50310` (`GRPC_PORT`).
