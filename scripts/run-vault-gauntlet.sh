#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Build and run the VaultGauntlet multi-act lean-grpc stress app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-50177}"
cd "$ROOT"
./scripts/build_native.sh >/dev/null 2>&1 || true
if [[ -x .lake/build/native/zlib_helper ]]; then
  export LEAN_GRPC_ZLIB_HELPER="$ROOT/.lake/build/native/zlib_helper"
fi
lake build vaultGauntletServer vaultGauntletClient
fuser -k "${PORT}/tcp" 2>/dev/null || true
GRPC_PORT="$PORT" ./.lake/build/bin/vaultGauntletServer > /tmp/vault-gauntlet-server.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 0.6
./.lake/build/bin/vaultGauntletClient 127.0.0.1 "$PORT"
ec=$?
if [[ "$ec" -ne 0 ]]; then
  echo "--- server log ---"
  cat /tmp/vault-gauntlet-server.log || true
fi
exit "$ec"
