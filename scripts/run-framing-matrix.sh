#!/usr/bin/env bash
# Peer-framing matrix: Lean↔Lean + Go→Lean against FramingMatrix server.
# Covers unary/server/client/bidi × identity/gzip × empty half-close × deadline/cancel/415.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-50310}"
cd "$ROOT"
./scripts/build_native.sh >/dev/null 2>&1 || true
if [[ -x .lake/build/native/zlib_helper ]]; then
  export LEAN_GRPC_ZLIB_HELPER="$ROOT/.lake/build/native/zlib_helper"
fi

lake build framingMatrixServer framingMatrixLeanClient
fuser -k "${PORT}/tcp" 2>/dev/null || true

GRPC_PORT="$PORT" ./.lake/build/bin/framingMatrixServer > /tmp/framing-matrix.log 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1.0

set +e
stdbuf -oL -eL ./.lake/build/bin/framingMatrixLeanClient 127.0.0.1 "$PORT"
ec_lean=$?
set -e

cd "$ROOT/Tests/FramingMatrix/go"
if [[ ! -f go.sum ]]; then
  go mod tidy
fi
set +e
stdbuf -oL -eL go run . 127.0.0.1 "$PORT"
ec_go=$?
set -e

if [[ "$ec_lean" -ne 0 || "$ec_go" -ne 0 ]]; then
  echo "--- server log ---"; cat /tmp/framing-matrix.log || true
  echo "lean_client_exit=$ec_lean go_client_exit=$ec_go"
  exit 1
fi
echo "FRAMING MATRIX OK (Lean + Go peers)"
