#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Lean interop client → Rust interop server (mirrors interop-lean-python.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10001}"
CASES=(
  empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin
  server_streaming client_streaming ping_pong empty_stream
  cancel_after_first_response special_status_message unimplemented_method unimplemented_service
  timeout_on_sleeping_server pick_first_unary
  server_compressed_unary server_compressed_streaming
)
# Note: cacheable_unary omitted — official case needs a caching proxy + CacheableUnaryCall.
cd "$ROOT"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found; install a Rust toolchain" >&2
  exit 1
fi

# Pin target dir so a redirected CARGO_TARGET_DIR (CI/sandbox) still matches SERVER path.
cargo build --manifest-path rust_interop/Cargo.toml --release \
  --target-dir "$ROOT/rust_interop/target"
SERVER="$ROOT/rust_interop/target/release/rust_interop_server"

lake build interopClient
fuser -k "${PORT}/tcp" 2>/dev/null || true
"$SERVER" --port="$PORT" > /tmp/lean-grpc-rs-server.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1

fail=0
for c in "${CASES[@]}"; do
  echo "== lean → rust: $c"
  if ! timeout 60 ./.lake/build/bin/interopClient 127.0.0.1 "$PORT" "$c"; then
    echo "FAIL $c"
    fail=$((fail + 1))
  fi
done
if [[ "$fail" -ne 0 ]]; then
  echo "interop-lean-rust FAILED ($fail)"
  exit 1
fi
echo "interop-lean-rust OK"
