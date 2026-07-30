#!/usr/bin/env bash
# Run full h2spec against the Lean h2c fixture (hard gate).
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

echo "h2spec FULL (hard gate)"
set +e
"$H2SPEC" -p "$PORT" -h 127.0.0.1 2>&1 | tee /tmp/lean-grpc-h2spec.txt
ec=${PIPESTATUS[0]}
set -e
if [[ "$ec" -ne 0 ]]; then
  echo "h2spec failed (exit=$ec)"
  exit "$ec"
fi
if grep -qE '[1-9][0-9]* failed' /tmp/lean-grpc-h2spec.txt; then
  echo "h2spec reported failures"
  exit 1
fi
echo "h2spec FULL green"
