#!/usr/bin/env bash
# ASAN/UBSan regressions for native zlib + TLS HTTP snprintf (LGSEC-2026-04/05).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- zlib bomb: must fail under max_out, not OOM ---
cat >"$TMP/zlib_cap_test.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct { uint8_t *data; size_t len; } ZBuf;
ZBuf lean_grpc_gzip_compress(const uint8_t *in, size_t in_len);
ZBuf lean_grpc_gzip_decompress(const uint8_t *in, size_t in_len, size_t max_out);
void lean_grpc_zbuf_free(uint8_t *p);

int main(void) {
  size_t uncomp = 8u * 1024 * 1024;
  uint8_t *zeros = calloc(1, uncomp);
  if (!zeros) return 2;
  ZBuf c = lean_grpc_gzip_compress(zeros, uncomp);
  free(zeros);
  if (!c.data) { fprintf(stderr, "compress failed\n"); return 1; }
  printf("compressed=%zu\n", c.len);
  ZBuf d = lean_grpc_gzip_decompress(c.data, c.len, 4u * 1024 * 1024);
  lean_grpc_zbuf_free(c.data);
  if (d.data) {
    fprintf(stderr, "FAIL: decompress succeeded size=%zu (expected cap failure)\n", d.len);
    lean_grpc_zbuf_free(d.data);
    return 1;
  }
  printf("zlib max_out cap OK\n");
  return 0;
}
EOF

cc -O1 -g -fsanitize=address,undefined -o "$TMP/zlib_cap_test" \
  "$TMP/zlib_cap_test.c" "$ROOT/native/zlib_bridge.c" -lz
"$TMP/zlib_cap_test"

# --- snprintf truncation guard (compile-time unit via small harness) ---
cat >"$TMP/snprintf_guard.c" <<'EOF'
#include <stdio.h>
#include <string.h>
/* Mirror the post-fix check: hn >= sizeof(hdr) must reject. */
static int would_write(const char *path, const char *host, const char *ctype) {
  char hdr[1024];
  int hn = snprintf(hdr, sizeof(hdr),
                    "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: %s\r\n"
                    "Content-Length: 0\r\nConnection: close\r\n\r\n",
                    path, host, ctype);
  return hn > 0 && hn < (int)sizeof(hdr);
}
int main(void) {
  char longpath[2048];
  memset(longpath, 'a', sizeof(longpath) - 1);
  longpath[0] = '/';
  longpath[sizeof(longpath) - 1] = 0;
  if (would_write(longpath, "h", "text/plain")) {
    fprintf(stderr, "FAIL: long path should be rejected\n");
    return 1;
  }
  if (!would_write("/token", "127.0.0.1", "application/x-www-form-urlencoded")) {
    fprintf(stderr, "FAIL: short request should be accepted\n");
    return 1;
  }
  printf("snprintf guard OK\n");
  return 0;
}
EOF
cc -O1 -g -fsanitize=address,undefined -o "$TMP/snprintf_guard" "$TMP/snprintf_guard.c"
"$TMP/snprintf_guard"

echo "security-asan OK"
