#!/usr/bin/env bash
# Lean server ← official Go gRPC interop client
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10000}"
CASES=(empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin)
GOBIN="${GOBIN:-$(go env GOPATH)/bin}"

cd "$ROOT"
if [[ ! -x "$GOBIN/client" ]]; then
  go install google.golang.org/grpc/interop/client@latest
fi
lake build interopServer
./.lake/build/bin/interopServer &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

for case in "${CASES[@]}"; do
  echo "== go client → lean server: $case"
  "$GOBIN/client" \
    --server_host=127.0.0.1 \
    --server_port="$PORT" \
    --use_tls=false \
    --test_case="$case"
done
echo "interop-lean-go OK"
