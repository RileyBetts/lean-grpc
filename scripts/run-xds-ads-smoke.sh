#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Fake ADS exercising the full xDS surface:
#   1. Direct EDS-by-cluster-name resolve (legacy path).
#   2. Full LDS → RDS → CDS → EDS chain over one ADS session.
#   3. A NACK path: a resource whose inner type_url is deliberately wrong.
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
# FakeAds speaks cleartext h2c — explicit insecure opt-in (LGSEC-2026-08).
export LEAN_GRPC_XDS_INSECURE=1
# Also prove bootstrap+env path
BOOT=/tmp/lean-grpc-xds-ads-bootstrap.json
cat >"$BOOT" <<EOF
{"xds_servers":[{"server_uri":"127.0.0.1:${ADS_PORT}"}],"clusters":{}}
EOF
export LEAN_GRPC_XDS_BOOTSTRAP="$BOOT"

./.lake/build/bin/interopClient 127.0.0.1 "$GRPC_PORT" xds_ads_unary
./.lake/build/bin/interopClient 127.0.0.1 "$GRPC_PORT" xds_ads_chain_unary
./.lake/build/bin/interopClient 127.0.0.1 "$GRPC_PORT" xds_ads_nack
grep -q "NACK received" /tmp/lean-grpc-fake-ads.log || {
  echo "expected FakeAds to log a NACK" >&2
  exit 1
}
echo "run-xds-ads-smoke OK"
