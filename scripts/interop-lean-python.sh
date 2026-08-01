#!/usr/bin/env bash
# Lean interop client → Python interop server (replaces Lean→Go matrix).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10001}"
CASES=(
  empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin
  server_streaming client_streaming ping_pong empty_stream
  cancel_after_first_response special_status_message unimplemented_method unimplemented_service
  timeout_on_sleeping_server pick_first_unary
  server_compressed_unary server_compressed_streaming
  cacheable_unary
)
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

if [[ ! -f python_interop/test_pb2_grpc.py ]]; then
  python -m grpc_tools.protoc -I python_interop/proto \
    --python_out=python_interop --grpc_python_out=python_interop \
    python_interop/proto/empty.proto python_interop/proto/messages.proto \
    python_interop/proto/test.proto
fi

lake build interopClient
fuser -k "${PORT}/tcp" 2>/dev/null || true
export PYTHONPATH="$ROOT/python_interop${PYTHONPATH:+:$PYTHONPATH}"
python python_interop/server.py --port="$PORT" > /tmp/lean-grpc-py-server.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1

fail=0
for c in "${CASES[@]}"; do
  echo "== lean → python: $c"
  if ! timeout 60 ./.lake/build/bin/interopClient 127.0.0.1 "$PORT" "$c"; then
    echo "FAIL $c"
    fail=$((fail + 1))
  fi
done
if [[ "$fail" -ne 0 ]]; then
  echo "interop-lean-python FAILED ($fail)"
  exit 1
fi
echo "interop-lean-python OK"
