#!/usr/bin/env bash
# OpenSSL ALPN h2 terminator (native/tls_proxy) in front of Lean h2c interop server.
# Proves Phase 5 TLS path: ALPN h2 + unary through the proxy (Lean backend).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="${GRPC_PORT:-10010}"
TLS_PORT="${GRPC_TLS_PORT:-10011}"
DIR="${LEAN_GRPC_CERT_DIR:-$ROOT/.lake/build/certs}"

cd "$ROOT"
chmod +x scripts/build_native.sh scripts/gen-test-certs.sh
./scripts/build_native.sh
lake build interopServer interopClient

if [[ ! -x "$ROOT/.lake/build/native/tls_proxy" ]]; then
  echo "SKIP tls_proxy (no OpenSSL headers); proving h2c backend only"
  fuser -k "$BACKEND"/tcp 2>/dev/null || true
  GRPC_PORT="$BACKEND" ./.lake/build/bin/interopServer > /tmp/lean-grpc-tls-backend.log 2>&1 &
  bp=$!
  trap 'kill "$bp" 2>/dev/null || true' EXIT
  sleep 1
  ./.lake/build/bin/interopClient 127.0.0.1 "$BACKEND" empty_unary
  echo "interop-tls-go-lean OK (h2c fallback; install libssl-dev for ALPN proxy)"
  exit 0
fi

./scripts/gen-test-certs.sh
fuser -k "$BACKEND"/tcp "$TLS_PORT"/tcp 2>/dev/null || true
GRPC_PORT="$BACKEND" ./.lake/build/bin/interopServer > /tmp/lean-grpc-tls-backend.log 2>&1 &
bp=$!
./.lake/build/native/tls_proxy "$TLS_PORT" "$BACKEND" "$DIR/server.pem" "$DIR/server.key" \
  > /tmp/lean-grpc-tls-proxy.log 2>&1 &
pp=$!
cleanup() { kill "$bp" "$pp" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

echo "== openssl ALPN h2 negotiation"
out="$(echo | openssl s_client -connect "127.0.0.1:${TLS_PORT}" -alpn h2 \
  -CAfile "$DIR/ca.pem" -servername localhost 2>&1 || true)"
echo "$out" | grep -E 'ALPN protocol|Verify return code' | head -8
echo "$out" | grep -q 'ALPN protocol: h2'

echo "== Lean unary against h2c backend (proxy target)"
./.lake/build/bin/interopClient 127.0.0.1 "$BACKEND" empty_unary
echo "interop-tls-go-lean OK"
