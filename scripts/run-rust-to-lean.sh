#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Rust interop client → Lean interop server (mirrors run-python-to-lean.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${GRPC_PORT:-10000}"
CASES=(
  empty_unary large_unary status_code_and_message custom_metadata cancel_after_begin
  server_streaming client_streaming ping_pong empty_stream
  cancel_after_first_response special_status_message unimplemented_method unimplemented_service
  timeout_on_sleeping_server
  client_compressed_unary server_compressed_unary server_compressed_streaming
)
# Note: cacheable_unary omitted (needs caching proxy + CacheableUnaryCall / GET).
cd "$ROOT"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found; install a Rust toolchain" >&2
  exit 1
fi

# Pin target dir so a redirected CARGO_TARGET_DIR (CI/sandbox) still matches CLIENT path.
cargo build --manifest-path rust_interop/Cargo.toml --release \
  --target-dir "$ROOT/rust_interop/target"
CLIENT="$ROOT/rust_interop/target/release/rust_interop_client"

lake build interopServer
fuser -k "${PORT}/tcp" 2>/dev/null || true
GRPC_PORT="$PORT" ./.lake/build/bin/interopServer > /tmp/lean-grpc-rs-interop.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1

fail=0
for c in "${CASES[@]}"; do
  echo "== rust → lean: $c"
  if ! timeout 60 "$CLIENT" \
      --server_host=127.0.0.1 --server_port="$PORT" --test_case="$c"; then
    echo "FAIL $c"
    fail=$((fail + 1))
  fi
done
if [[ "$fail" -ne 0 ]]; then
  echo "run-rust-to-lean FAILED ($fail)"
  exit 1
fi
echo "run-rust-to-lean OK"
