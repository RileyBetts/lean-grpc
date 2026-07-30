#!/usr/bin/env bash
# Run h2spec core sections against the Lean h2c fixture (hard gate).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${H2SPEC_PORT:-50051}"
cd "$ROOT"
lake build h2specServer
./.lake/build/bin/h2specServer &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1

H2SPEC="${H2SPEC:-}"
if [[ -z "$H2SPEC" ]]; then
  if command -v h2spec >/dev/null 2>&1; then
    H2SPEC=h2spec
  else
    ver="v2.6.0"
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) echo "unsupported arch $arch"; exit 1 ;;
    esac
    url="https://github.com/summerwind/h2spec/releases/download/${ver}/h2spec_linux_${arch}.tar.gz"
    tmp="$(mktemp -d)"
    curl -fsSL "$url" | tar -xz -C "$tmp"
    H2SPEC="$tmp/h2spec"
  fi
fi

# Core hard-gate sections (must be fully green). Broader suite remains soft.
CORE=(http2/3.5 http2/4.1 http2/6.5 http2/6.7 http2/6.8)
echo "h2spec CORE: ${CORE[*]}"
set +e
"$H2SPEC" -p "$PORT" -h 127.0.0.1 "${CORE[@]}" 2>&1 | tee /tmp/lean-grpc-h2spec-core.txt
ec=${PIPESTATUS[0]}
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "h2spec CORE failed (exit=$ec)"
  exit "$ec"
fi
if grep -q 'failed$' /tmp/lean-grpc-h2spec-core.txt 2>/dev/null || \
   grep -qE '^[0-9]+ tests, .* [1-9][0-9]* failed' /tmp/lean-grpc-h2spec-core.txt; then
  # h2spec sometimes exits 0 with failures printed; treat any failure count as hard fail
  if grep -qE '[1-9][0-9]* failed' /tmp/lean-grpc-h2spec-core.txt; then
    echo "h2spec CORE reported failures"
    exit 1
  fi
fi

# Soft full run for artifacts (do not fail CI).
set +e
"$H2SPEC" -p "$PORT" -h 127.0.0.1 2>&1 | tee /tmp/lean-grpc-h2spec.txt
set -e
echo "h2spec CORE green; full suite logged to /tmp/lean-grpc-h2spec.txt"
