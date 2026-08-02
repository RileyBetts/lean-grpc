#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Lean client → official Go gRPC interop server
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10001}"
CASES=(
  empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin
  server_streaming client_streaming ping_pong empty_stream
  cancel_after_first_response special_status_message unimplemented_method unimplemented_service
  timeout_on_sleeping_server pick_first_unary
  server_compressed_unary server_compressed_streaming
)
# Note: cacheable_unary omitted against official grpc-go server — recent servers
# return INTERNAL for GET EmptyCall; Lean↔Lean still exercises the GET verb wire check.
GOBIN="${GOBIN:-$(go env GOPATH)/bin}"

cd "$ROOT"
./scripts/build_native.sh || true
export LEAN_GRPC_ZLIB_HELPER="${LEAN_GRPC_ZLIB_HELPER:-$ROOT/.lake/build/native/zlib_helper}"
if [[ ! -x "$GOBIN/server" ]]; then
  go install google.golang.org/grpc/interop/server@v1.73.0
fi
lake build interopClient
fuser -k "$PORT"/tcp 2>/dev/null || true
"$GOBIN/server" --use_tls=false --port="$PORT" &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

for case in "${CASES[@]}"; do
  echo "== lean client → go server: $case"
  timeout 60 ./.lake/build/bin/interopClient 127.0.0.1 "$PORT" "$case"
done
echo "interop-go-lean OK"
