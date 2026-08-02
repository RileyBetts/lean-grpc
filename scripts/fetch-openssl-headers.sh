#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Fetch/generate OpenSSL headers when libssl-dev is unavailable (no sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEP="$ROOT/.lake/deps"
VER=3.0.13
# sha256 of openssl-3.0.13.tar.gz from GitHub Releases (LGSEC-2026-21).
SHA256=88525753f79d3bec27d2fa7c66aa0b92b3aa9498dafd93d7cfa4b3780cdae313
if [[ -f /usr/include/openssl/ssl.h ]]; then
  echo "system openssl headers present"
  exit 0
fi
if [[ -f "$DEP/openssl-$VER/include/openssl/ssl.h" ]]; then
  echo "local openssl headers present"
  exit 0
fi
mkdir -p "$DEP"
cd "$DEP"
curl -fsSL -o openssl.tgz "https://github.com/openssl/openssl/releases/download/openssl-${VER}/openssl-${VER}.tar.gz"
echo "${SHA256}  openssl.tgz" | shasum -a 256 -c -
tar xzf openssl.tgz
rm openssl.tgz
cd "openssl-$VER"
./Configure --prefix="$DEP/openssl-prefix" no-tests no-shared >/dev/null
jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
make -j"$jobs" build_generated >/dev/null
test -f include/openssl/ssl.h
echo "generated $DEP/openssl-$VER/include"
