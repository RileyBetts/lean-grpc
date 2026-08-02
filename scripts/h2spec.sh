#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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
      x86_64|amd64) arch=amd64; sha256=157ee0de702e01ad40e752dbf074b366027e550c8e7504f9450da2809e279318 ;;
      *)
        echo "unsupported arch $arch for auto-download (install h2spec or set H2SPEC=)"
        exit 1
        ;;
    esac
    url="https://github.com/summerwind/h2spec/releases/download/${ver}/h2spec_linux_${arch}.tar.gz"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/h2spec.tgz" "$url"
    echo "${sha256}  $tmp/h2spec.tgz" | shasum -a 256 -c -
    tar -xz -C "$tmp" -f "$tmp/h2spec.tgz"
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
