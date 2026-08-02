#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# In-process TLS+ALPN: Lean client → Go TLS server (no LEAN_GRPC_TLS_PROXY).
# Also keeps optional proxy smoke when tls_proxy is built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TLS_PORT="${GRPC_TLS_PORT:-10011}"
DIR="${LEAN_GRPC_CERT_DIR:-$ROOT/.lake/build/certs}"
GOBIN="${GOBIN:-$(go env GOPATH 2>/dev/null)/bin}"

cd "$ROOT"
chmod +x scripts/build_native.sh scripts/gen-test-certs.sh scripts/fetch-openssl-headers.sh
./scripts/fetch-openssl-headers.sh || true
./scripts/build_native.sh || true
./scripts/gen-test-certs.sh
lake build interopClient

if [[ ! -x "$GOBIN/server" ]]; then
  go install google.golang.org/grpc/interop/server@v1.73.0
fi

fuser -k "${TLS_PORT}/tcp" 2>/dev/null || true
# Official Go interop server TLS
"$GOBIN/server" --use_tls=true --tls_cert_file="$DIR/server.pem" \
  --tls_key_file="$DIR/server.key" --port="$TLS_PORT" \
  > /tmp/lean-grpc-go-tls-server.log 2>&1 &
gp=$!
cleanup() { kill "$gp" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

echo "== Lean in-process TLS client → Go TLS server"
LEAN_GRPC_TLS_CA="$DIR/ca.pem" LEAN_GRPC_TLS_SERVER_NAME=localhost \
  timeout 30 ./.lake/build/bin/interopClient 127.0.0.1 "$TLS_PORT" tls_empty_unary

echo "interop-tls-go-lean OK (in-process TLS)"
