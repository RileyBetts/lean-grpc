#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
set -euo pipefail
cd "$(dirname "$0")/.."
# Official grpc-go interop client cases supported by the stock `client` binary.
# Note: `cacheable_unary` is intentionally omitted here — the official client's
# assertions require the server to sit behind a real caching proxy (it expects
# two back-to-back CacheableUnaryCall responses to be byte-identical), which is
# out of scope for this smoke matrix. See docs/conformance.md.
CASES=(
  empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin
  server_streaming client_streaming ping_pong empty_stream
  cancel_after_first_response special_status_message unimplemented_method unimplemented_service
  timeout_on_sleeping_server
)
lake build interopServer
fuser -k 10000/tcp 2>/dev/null || true
./.lake/build/bin/interopServer > /tmp/lean-grpc-interop.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1
for c in "${CASES[@]}"; do
  echo "== $c"
  timeout 60 "$(go env GOPATH)/bin/client" --server_host=127.0.0.1 --server_port=10000 --use_tls=false --test_case="$c"
done
echo OK
