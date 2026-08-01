#!/usr/bin/env bash
# rpc_soak / channel_soak smoke: runs benchSoak against a local helloworldServer with both
# calling conventions:
#   1. Legacy positional iteration count (back-compat with the original `benchSoak host port N`).
#   2. grpc-style `--soak_*` flags, including channel_soak's multi-channel + reset-per-iteration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRPC_PORT="${GRPC_PORT:-50051}"
cd "$ROOT"
lake build helloworldServer benchSoak

fuser -k "${GRPC_PORT}/tcp" 2>/dev/null || true
./.lake/build/bin/helloworldServer >/tmp/lean-grpc-soak-server.log 2>&1 &
spid=$!
cleanup() { kill "$spid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5

echo "-- rpc_soak (legacy positional iterations) --"
./.lake/build/bin/benchSoak 127.0.0.1 "$GRPC_PORT" 20

echo "-- rpc_soak (--soak_* flags) --"
./.lake/build/bin/benchSoak 127.0.0.1 "$GRPC_PORT" \
  --soak_iterations=20 \
  --soak_max_failures=0 \
  --soak_per_iteration_max_acceptable_latency_ms=2000 \
  --soak_min_time_ms_between_rpcs=0 \
  --soak_overall_timeout_seconds=10 \
  --soak_request_size=64

echo "-- channel_soak (multiple channels, reset per iteration) --"
./.lake/build/bin/benchSoak 127.0.0.1 "$GRPC_PORT" \
  --soak_iterations=12 \
  --soak_num_channels=3 \
  --soak_reset_channel_per_iteration=true

echo "run-soak OK"
