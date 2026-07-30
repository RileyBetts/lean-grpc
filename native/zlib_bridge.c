/* Thin zlib FFI for peer-compatible gzip (deflate/inflate). */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct {
  uint8_t *data;
  size_t len;
} ZBuf;

static ZBuf zbuf_fail(void) {
  ZBuf b = {NULL, 0};
  return b;
}

/* Gzip-compress payload; caller frees data with lean_grpc_zbuf_free. */
ZBuf lean_grpc_gzip_compress(const uint8_t *in, size_t in_len) {
  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK)
    return zbuf_fail();
  size_t bound = deflateBound(&strm, in_len) + 64;
  uint8_t *out = (uint8_t *)malloc(bound);
  if (!out) {
    deflateEnd(&strm);
    return zbuf_fail();
  }
  strm.next_in = (Bytef *)in;
  strm.avail_in = (uInt)in_len;
  strm.next_out = out;
  strm.avail_out = (uInt)bound;
  int rc = deflate(&strm, Z_FINISH);
  size_t n = bound - strm.avail_out;
  deflateEnd(&strm);
  if (rc != Z_STREAM_END) {
    free(out);
    return zbuf_fail();
  }
  ZBuf b = {out, n};
  return b;
}

ZBuf lean_grpc_gzip_decompress(const uint8_t *in, size_t in_len) {
  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  if (inflateInit2(&strm, 15 + 16) != Z_OK)
    return zbuf_fail();
  size_t cap = in_len * 4 + 64;
  uint8_t *out = (uint8_t *)malloc(cap);
  if (!out) {
    inflateEnd(&strm);
    return zbuf_fail();
  }
  strm.next_in = (Bytef *)in;
  strm.avail_in = (uInt)in_len;
  strm.next_out = out;
  strm.avail_out = (uInt)cap;
  for (;;) {
    int rc = inflate(&strm, Z_NO_FLUSH);
    if (rc == Z_STREAM_END)
      break;
    if (rc != Z_OK) {
      free(out);
      inflateEnd(&strm);
      return zbuf_fail();
    }
    if (strm.avail_out == 0) {
      size_t used = cap;
      cap *= 2;
      uint8_t *nbuf = (uint8_t *)realloc(out, cap);
      if (!nbuf) {
        free(out);
        inflateEnd(&strm);
        return zbuf_fail();
      }
      out = nbuf;
      strm.next_out = out + used;
      strm.avail_out = (uInt)(cap - used);
    }
  }
  size_t n = cap - strm.avail_out;
  inflateEnd(&strm);
  ZBuf b = {out, n};
  return b;
}

void lean_grpc_zbuf_free(uint8_t *p) {
  free(p);
}
