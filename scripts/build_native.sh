#!/usr/bin/env bash
# Build optional native bridges (zlib helper; OpenSSL tls_proxy when headers available).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.lake/build/native"
mkdir -p "$OUT"

cc -fPIC -O2 -c "$ROOT/native/zlib_bridge.c" -o "$OUT/zlib_bridge.o"
ar rcs "$OUT/liblean_grpc_native.a" "$OUT/zlib_bridge.o"
cc -O2 -o "$OUT/zlib_helper" "$ROOT/native/zlib_helper.c" "$OUT/zlib_bridge.o" -lz
echo "built $OUT/zlib_helper"
echo "export LEAN_GRPC_ZLIB_HELPER=$OUT/zlib_helper"

OPENSSL_CFLAGS="$(pkg-config --cflags openssl 2>/dev/null || true)"
OPENSSL_LIBS="$(pkg-config --libs openssl 2>/dev/null || echo "-lssl -lcrypto")"
if [[ -f /usr/include/openssl/ssl.h ]] || echo "$OPENSSL_CFLAGS" | grep -q -- '-I'; then
  cc -fPIC -O2 -c "$ROOT/native/tls_bridge.c" -o "$OUT/tls_bridge.o" $OPENSSL_CFLAGS
  ar rcs "$OUT/liblean_grpc_native.a" "$OUT/zlib_bridge.o" "$OUT/tls_bridge.o"
  cc -O2 -o "$OUT/tls_proxy" "$ROOT/native/tls_proxy.c" $OPENSSL_CFLAGS $OPENSSL_LIBS -lpthread
  echo "built $OUT/tls_proxy"
else
  echo "WARN: OpenSSL headers not found; skipping tls_proxy (install libssl-dev)"
fi
