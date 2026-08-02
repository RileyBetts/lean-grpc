#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Compression matrix: Go gzip client → Lean; Lean client → Go gzip-enabled server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT_GO_CLIENT="${GRPC_PORT:-10002}"
PORT_GO_SERVER="${GRPC_COMPRESS_PORT:-10005}"
cd "$ROOT"

./scripts/build_native.sh || true
export LEAN_GRPC_ZLIB_HELPER="${LEAN_GRPC_ZLIB_HELPER:-$ROOT/.lake/build/native/zlib_helper}"
lake build interopServer interopClient

echo "== Go gzip client → Lean (unary)"
fuser -k "${PORT_GO_CLIENT}/tcp" 2>/dev/null || true
GRPC_PORT="$PORT_GO_CLIENT" ./.lake/build/bin/interopServer >/tmp/lean-grpc-compress-srv.log 2>&1 &
lp=$!
cleanup1() { kill "$lp" 2>/dev/null || true; }
trap cleanup1 EXIT
sleep 0.5
(
  cd Tests/GoGzip
  go mod tidy 2>/dev/null || true
  go run . 127.0.0.1 "$PORT_GO_CLIENT"
)

echo "== Lean client → Go gzip server (compressed cases)"
kill "$lp" 2>/dev/null || true
trap - EXIT
fuser -k "${PORT_GO_SERVER}/tcp" 2>/dev/null || true

(
  cd Tests/GoGzipServer
  go mod tidy 2>/dev/null || true
  go build -o "$ROOT/.lake/build/native/go_gzip_interop_server" .
)
./.lake/build/native/go_gzip_interop_server -port="$PORT_GO_SERVER" \
  >/tmp/lean-grpc-go-gzip-srv.log 2>&1 &
gp=$!
cleanup2() { kill "$gp" 2>/dev/null || true; }
trap cleanup2 EXIT
for _ in $(seq 1 50); do
  if (echo >/dev/tcp/127.0.0.1/"$PORT_GO_SERVER") >/dev/null 2>&1; then break; fi
  sleep 0.1
done

for c in client_compressed_unary client_compressed_streaming \
         server_compressed_unary server_compressed_streaming; do
  echo "== lean → go-gzip: $c"
  timeout 60 ./.lake/build/bin/interopClient 127.0.0.1 "$PORT_GO_SERVER" "$c"
done
echo "interop-compress-go-lean OK"
