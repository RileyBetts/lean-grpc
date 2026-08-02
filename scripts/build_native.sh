#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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
LEAN_INC="$(lean --print-prefix 2>/dev/null)/include"
LOCAL_SSL_INC="$ROOT/.lake/deps/openssl-3.0.13/include"
if [[ ! -f /usr/include/openssl/ssl.h ]] && [[ -z "$OPENSSL_CFLAGS" ]]; then
  if [[ -f "$LOCAL_SSL_INC/openssl/ssl.h" ]] || "$ROOT/scripts/fetch-openssl-headers.sh"; then
    OPENSSL_CFLAGS="-I$LOCAL_SSL_INC"
  fi
fi
if [[ -f /usr/include/openssl/ssl.h ]] || [[ -n "$OPENSSL_CFLAGS" ]]; then
  cc -fPIC -O2 -c "$ROOT/native/tls_bridge.c" -o "$OUT/tls_bridge.o" $OPENSSL_CFLAGS
  if [[ -f "$LEAN_INC/lean/lean.h" ]]; then
    cc -fPIC -O2 -c "$ROOT/native/tls_ffi.c" -o "$OUT/tls_ffi.o" $OPENSSL_CFLAGS -I"$LEAN_INC"
    ar rcs "$OUT/liblean_grpc_native.a" "$OUT/zlib_bridge.o" "$OUT/tls_bridge.o" "$OUT/tls_ffi.o"
    echo "built $OUT/tls_ffi.o (in-process TLS FFI)"
  else
    ar rcs "$OUT/liblean_grpc_native.a" "$OUT/zlib_bridge.o" "$OUT/tls_bridge.o"
    echo "WARN: lean.h not found; Lake builds tls_ffi.o instead"
  fi
  if cc -O2 -o "$OUT/tls_proxy" "$ROOT/native/tls_proxy.c" $OPENSSL_CFLAGS $OPENSSL_LIBS -lpthread 2>/dev/null; then
    echo "built $OUT/tls_proxy"
  else
    echo "WARN: tls_proxy link skipped (openssl link libs missing)"
  fi
else
  echo "WARN: OpenSSL headers not found; skipping tls_proxy (install libssl-dev or run fetch-openssl-headers.sh)"
fi
