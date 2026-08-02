/* Copyright © 2026, Riley Betts Ltd (rileybetts.ai) */
/* stdin/stdout zlib gzip filter used when LEAN_GRPC_ZLIB_HELPER is set. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  uint8_t *data;
  size_t len;
} ZBuf;

ZBuf lean_grpc_gzip_compress(const uint8_t *in, size_t in_len);
ZBuf lean_grpc_gzip_decompress(const uint8_t *in, size_t in_len);
void lean_grpc_zbuf_free(uint8_t *p);

static int read_all(uint8_t **out, size_t *out_len) {
  size_t cap = 4096, n = 0;
  uint8_t *buf = (uint8_t *)malloc(cap);
  if (!buf) return -1;
  for (;;) {
    if (n == cap) {
      cap *= 2;
      uint8_t *nb = (uint8_t *)realloc(buf, cap);
      if (!nb) { free(buf); return -1; }
      buf = nb;
    }
    size_t r = fread(buf + n, 1, cap - n, stdin);
    n += r;
    if (r == 0) break;
  }
  *out = buf;
  *out_len = n;
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: zlib_helper compress|decompress\n");
    return 2;
  }
  uint8_t *in = NULL;
  size_t in_len = 0;
  if (read_all(&in, &in_len) != 0) return 1;
  ZBuf z;
  if (strcmp(argv[1], "compress") == 0)
    z = lean_grpc_gzip_compress(in, in_len);
  else if (strcmp(argv[1], "decompress") == 0)
    z = lean_grpc_gzip_decompress(in, in_len);
  else {
    free(in);
    return 2;
  }
  free(in);
  if (!z.data) return 1;
  fwrite(z.data, 1, z.len, stdout);
  lean_grpc_zbuf_free(z.data);
  return 0;
}
