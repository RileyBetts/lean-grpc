#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
lake build interopServer
./.lake/build/bin/interopServer > /tmp/lean-grpc-interop.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1
for c in empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin; do
  echo "== $c"
  "$(go env GOPATH)/bin/client" --server_host=127.0.0.1 --server_port=10000 --use_tls=false --test_case="$c"
done
echo OK
