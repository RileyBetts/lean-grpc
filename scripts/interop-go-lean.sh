#!/usr/bin/env bash
# Lean client → official Go gRPC interop server
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10001}"
CASES=(
  empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin
  server_streaming client_streaming ping_pong empty_stream
)
GOBIN="${GOBIN:-$(go env GOPATH)/bin}"

cd "$ROOT"
if [[ ! -x "$GOBIN/server" ]]; then
  go install google.golang.org/grpc/interop/server@latest
fi
lake build interopClient

"$GOBIN/server" --port="$PORT" --use_tls=false &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

for case in "${CASES[@]}"; do
  echo "== lean client → go server: $case"
  ./.lake/build/bin/interopClient 127.0.0.1 "$PORT" "$case"
done
echo "interop-go-lean OK"
