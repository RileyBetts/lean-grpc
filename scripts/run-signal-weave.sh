#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Go client → Lean SignalWeave spectrum-exchange demo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-50301}"
cd "$ROOT"
./scripts/build_native.sh >/dev/null 2>&1 || true
if [[ -x .lake/build/native/zlib_helper ]]; then
  export LEAN_GRPC_ZLIB_HELPER="$ROOT/.lake/build/native/zlib_helper"
fi

lake build signalWeaveServer
fuser -k "${PORT}/tcp" 2>/dev/null || true

GRPC_PORT="$PORT" ./.lake/build/bin/signalWeaveServer > /tmp/signal-weave.log 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1.0

cd "$ROOT/Examples/SignalWeave/go"
if [[ ! -f go.sum ]]; then
  go mod tidy
fi
set +e
if command -v stdbuf >/dev/null 2>&1; then
  stdbuf -oL -eL go run . 127.0.0.1 "$PORT"
else
  go run . 127.0.0.1 "$PORT"
fi
ec=$?
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "--- server log ---"; cat /tmp/signal-weave.log || true
fi
exit "$ec"
