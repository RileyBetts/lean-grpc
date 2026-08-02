#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Lean↔Lean MirrorForge dual-backend stress demo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT_A="${GRPC_PORT_A:-50201}"
PORT_B="${GRPC_PORT_B:-50202}"
cd "$ROOT"
./scripts/build_native.sh >/dev/null 2>&1 || true
if [[ -x .lake/build/native/zlib_helper ]]; then
  export LEAN_GRPC_ZLIB_HELPER="$ROOT/.lake/build/native/zlib_helper"
fi
lake build mirrorForgeServer mirrorForgeClient
fuser -k "${PORT_A}/tcp" "${PORT_B}/tcp" 2>/dev/null || true

FORGE_ID=alpha GRPC_PORT="$PORT_A" ./.lake/build/bin/mirrorForgeServer \
  > /tmp/mirror-forge-alpha.log 2>&1 &
pid_a=$!
FORGE_ID=beta GRPC_PORT="$PORT_B" ./.lake/build/bin/mirrorForgeServer \
  > /tmp/mirror-forge-beta.log 2>&1 &
pid_b=$!
cleanup() { kill "$pid_a" "$pid_b" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1.0

export LEAN_GRPC_RESOLVE_ADDRS="127.0.0.1:${PORT_A},127.0.0.1:${PORT_B}"
set +e
stdbuf -oL -eL ./.lake/build/bin/mirrorForgeClient 127.0.0.1 "$PORT_A" "$PORT_B"
ec=$?
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "--- alpha log ---"; cat /tmp/mirror-forge-alpha.log || true
  echo "--- beta log ---"; cat /tmp/mirror-forge-beta.log || true
fi
exit "$ec"
