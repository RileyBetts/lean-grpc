#!/usr/bin/env bash
# Python interop client → Lean interop server (replaces Go→Lean matrix).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10000}"
CASES=(
  empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin
  server_streaming client_streaming ping_pong empty_stream
  cancel_after_first_response special_status_message unimplemented_method unimplemented_service
  timeout_on_sleeping_server
  client_compressed_unary server_compressed_unary server_compressed_streaming
)
# Note: cacheable_unary omitted (needs caching proxy + CacheableUnaryCall / GET).
cd "$ROOT"

if [[ ! -d .venv-interop ]]; then
  python3 -m venv .venv-interop
  # shellcheck disable=SC1091
  source .venv-interop/bin/activate
  pip install -q --upgrade pip
  pip install -q 'grpcio>=1.62' 'grpcio-tools>=1.62' protobuf
else
  # shellcheck disable=SC1091
  source .venv-interop/bin/activate
fi

# Ensure stubs exist
if [[ ! -f python_interop/test_pb2_grpc.py ]]; then
  python -m grpc_tools.protoc -I python_interop/proto \
    --python_out=python_interop --grpc_python_out=python_interop \
    python_interop/proto/empty.proto python_interop/proto/messages.proto \
    python_interop/proto/test.proto
fi

lake build interopServer
fuser -k "${PORT}/tcp" 2>/dev/null || true
GRPC_PORT="$PORT" ./.lake/build/bin/interopServer > /tmp/lean-grpc-py-interop.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1

export PYTHONPATH="$ROOT/python_interop${PYTHONPATH:+:$PYTHONPATH}"
fail=0
for c in "${CASES[@]}"; do
  echo "== python → lean: $c"
  if ! timeout 60 python python_interop/client.py \
      --server_host=127.0.0.1 --server_port="$PORT" --test_case="$c"; then
    echo "FAIL $c"
    fail=$((fail + 1))
  fi
done
if [[ "$fail" -ne 0 ]]; then
  echo "run-python-to-lean FAILED ($fail)"
  exit 1
fi
echo "run-python-to-lean OK"
