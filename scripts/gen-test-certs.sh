#!/usr/bin/env bash
# Generate a short-lived test CA + server cert for TLS interop.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${LEAN_GRPC_CERT_DIR:-$ROOT/.lake/build/certs}"
mkdir -p "$DIR"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DIR/ca.key" -out "$DIR/ca.pem" \
  -days 2 -subj "/CN=lean-grpc-test-ca" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$DIR/server.key" -out "$DIR/server.csr" \
  -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in "$DIR/server.csr" -CA "$DIR/ca.pem" -CAkey "$DIR/ca.key" -CAcreateserial \
  -out "$DIR/server.pem" -days 2 \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1") 2>/dev/null
echo "certs in $DIR"
