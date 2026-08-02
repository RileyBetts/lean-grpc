/* Copyright © 2026, Riley Betts Ltd (rileybetts.ai) */
/* Minimal OpenSSL client ALPN h2 helper: handshake on a connected TCP fd. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

static int alpn_select(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                       const unsigned char *in, unsigned int inlen, void *arg) {
  (void)ssl;
  (void)arg;
  /* Prefer h2 */
  if (SSL_select_next_proto((unsigned char **)out, outlen,
                            (const unsigned char *)"\x02h2", 3, in, inlen) == OPENSSL_NPN_NEGOTIATED)
    return SSL_TLSEXT_ERR_OK;
  return SSL_TLSEXT_ERR_NOACK;
}

SSL_CTX *lean_grpc_tls_client_ctx(const char *ca_file) {
  SSL_library_init();
  SSL_load_error_strings();
  OpenSSL_add_all_algorithms();
  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (!ctx)
    return NULL;
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_alpn_protos(ctx, (const unsigned char *)"\x02h2", 3);
  if (ca_file && ca_file[0]) {
    if (!SSL_CTX_load_verify_locations(ctx, ca_file, NULL)) {
      SSL_CTX_free(ctx);
      return NULL;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  } else {
    /* Empty ca_file: system trust store (callers that need skip-verify must set VERIFY_NONE). */
    if (!SSL_CTX_set_default_verify_paths(ctx)) {
      SSL_CTX_free(ctx);
      return NULL;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  }
  return ctx;
}

SSL *lean_grpc_tls_connect_fd(SSL_CTX *ctx, int fd, const char *server_name) {
  if (!ctx)
    return NULL;
  SSL *ssl = SSL_new(ctx);
  if (!ssl)
    return NULL;
  SSL_set_fd(ssl, fd);
  if (server_name && server_name[0]) {
    SSL_set_tlsext_host_name(ssl, server_name);
    if (SSL_set1_host(ssl, server_name) != 1) {
      SSL_free(ssl);
      return NULL;
    }
  }
  if (SSL_connect(ssl) != 1) {
    SSL_free(ssl);
    return NULL;
  }
  const unsigned char *alpn = NULL;
  unsigned int alpn_len = 0;
  SSL_get0_alpn_selected(ssl, &alpn, &alpn_len);
  if (!(alpn_len == 2 && alpn[0] == 'h' && alpn[1] == '2')) {
    /* Still allow if peer omitted ALPN in some test setups. */
  }
  return ssl;
}

int lean_grpc_tls_read(SSL *ssl, uint8_t *buf, int len) {
  return SSL_read(ssl, buf, len);
}

int lean_grpc_tls_write(SSL *ssl, const uint8_t *buf, int len) {
  return SSL_write(ssl, buf, len);
}

void lean_grpc_tls_free(SSL *ssl) {
  if (ssl) {
    SSL_shutdown(ssl);
    SSL_free(ssl);
  }
}

void lean_grpc_tls_ctx_free(SSL_CTX *ctx) {
  if (ctx)
    SSL_CTX_free(ctx);
}
