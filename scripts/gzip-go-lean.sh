#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Go client (gzip compressor) → Lean interop server UnaryCall.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10000}"
cd "$ROOT"
lake build interopServer
./.lake/build/bin/interopServer &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1
(
  cd Tests/GoGzip
  go mod tidy 2>/dev/null || true
  go run . 127.0.0.1 "$PORT"
)
echo "gzip-go-lean OK"
