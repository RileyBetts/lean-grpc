#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# ADC smoke against local metadata/token mock.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${ADC_MOCK_PORT:-18080}"
DIR="$ROOT/.lake/build/adc-fixtures"
cd "$ROOT"
chmod +x scripts/mock-adc-server.py
mkdir -p "$DIR"

# RSA key + minimal SA JSON
if [[ ! -f "$DIR/sa.json" ]]; then
  openssl genrsa -out "$DIR/sa.pem" 2048 2>/dev/null
  # Escape PEM for JSON
  key_json=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' "$DIR/sa.pem")
  cat > "$DIR/sa.json" <<EOF
{"type":"service_account","client_email":"lean-adc@example.com","private_key":"$key_json","token_uri":"https://oauth2.googleapis.com/token"}
EOF
fi

fuser -k "${PORT}/tcp" 2>/dev/null || true
python3 scripts/mock-adc-server.py --port="$PORT" >/tmp/lean-grpc-adc-mock.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 0.3

lake build adcSmoke
export LEAN_GRPC_ALLOW_ADC_OVERRIDE=1
export LEAN_GRPC_GCE_METADATA="127.0.0.1:${PORT}"
export LEAN_GRPC_TOKEN_INSECURE=1
export LEAN_GRPC_TOKEN_HOST="127.0.0.1:${PORT}"
export LEAN_GRPC_TOKEN_PATH=/token
export GOOGLE_APPLICATION_CREDENTIALS="$DIR/sa.json"
./.lake/build/bin/adcSmoke
echo "run-adc-smoke OK"
