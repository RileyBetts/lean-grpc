#!/usr/bin/env bash
# Fake ADS → Lean client resolves xds:///test → unary against Lean interop server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADS_PORT="${ADS_PORT:-18000}"
GRPC_PORT="${GRPC_PORT:-10000}"
cd "$ROOT"
lake build fakeAdsServer interopServer interopClient

fuser -k "${ADS_PORT}/tcp" "${GRPC_PORT}/tcp" 2>/dev/null || true
GRPC_PORT="$GRPC_PORT" ./.lake/build/bin/interopServer >/tmp/lean-grpc-ads-interop.log 2>&1 &
ipid=$!
./.lake/build/bin/fakeAdsServer "$ADS_PORT" "127.0.0.1:${GRPC_PORT}" test \
  >/tmp/lean-grpc-fake-ads.log 2>&1 &
apid=$!
cleanup() { kill "$ipid" "$apid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5

export LEAN_GRPC_FAKE_ADS="127.0.0.1:${ADS_PORT}"
# Also prove bootstrap+env path
BOOT=/tmp/lean-grpc-xds-ads-bootstrap.json
cat >"$BOOT" <<EOF
{"xds_servers":[{"server_uri":"127.0.0.1:${ADS_PORT}"}],"clusters":{}}
EOF
export LEAN_GRPC_XDS_BOOTSTRAP="$BOOT"

./.lake/build/bin/interopClient 127.0.0.1 "$GRPC_PORT" xds_ads_unary
echo "run-xds-ads-smoke OK"
