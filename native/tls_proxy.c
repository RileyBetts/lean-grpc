/*
 * Minimal TLS terminator: accept TLS+ALPN h2, forward bytes to backend h2c.
 * Usage: tls_proxy <listen_port> <backend_port> <cert.pem> <key.pem>
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int alpn_select(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                       const unsigned char *in, unsigned int inlen, void *arg) {
  (void)ssl; (void)arg;
  if (SSL_select_next_proto((unsigned char **)out, outlen,
                            (const unsigned char *)"\x02h2", 3, in, inlen) == OPENSSL_NPN_NEGOTIATED)
    return SSL_TLSEXT_ERR_OK;
  return SSL_TLSEXT_ERR_NOACK;
}

struct Relay {
  SSL *ssl;
  int backend;
};

static void *ssl_to_backend(void *arg) {
  struct Relay *r = (struct Relay *)arg;
  unsigned char buf[16384];
  for (;;) {
    int n = SSL_read(r->ssl, buf, sizeof(buf));
    if (n <= 0) break;
    if (write(r->backend, buf, (size_t)n) != n) break;
  }
  shutdown(r->backend, SHUT_WR);
  return NULL;
}

static void *backend_to_ssl(void *arg) {
  struct Relay *r = (struct Relay *)arg;
  unsigned char buf[16384];
  for (;;) {
    int n = (int)read(r->backend, buf, sizeof(buf));
    if (n <= 0) break;
    if (SSL_write(r->ssl, buf, n) != n) break;
  }
  SSL_shutdown(r->ssl);
  return NULL;
}

static int connect_backend(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(fd);
    return -1;
  }
  return fd;
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: %s <listen_port> <backend_port> <cert.pem> <key.pem>\n", argv[0]);
    return 2;
  }
  int listen_port = atoi(argv[1]);
  int backend_port = atoi(argv[2]);
  SSL_library_init();
  SSL_load_error_strings();
  OpenSSL_add_all_algorithms();
  SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) return 1;
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_alpn_select_cb(ctx, alpn_select, NULL);
  if (SSL_CTX_use_certificate_file(ctx, argv[3], SSL_FILETYPE_PEM) != 1) return 1;
  if (SSL_CTX_use_PrivateKey_file(ctx, argv[4], SSL_FILETYPE_PEM) != 1) return 1;

  int ls = socket(AF_INET, SOCK_STREAM, 0);
  int yes = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)listen_port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) < 0) return 1;
  if (listen(ls, 16) < 0) return 1;
  fprintf(stderr, "tls_proxy listening on %d → h2c %d\n", listen_port, backend_port);

  for (;;) {
    int cfd = accept(ls, NULL, NULL);
    if (cfd < 0) continue;
    SSL *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, cfd);
    if (SSL_accept(ssl) != 1) {
      SSL_free(ssl);
      close(cfd);
      continue;
    }
    int backend = connect_backend(backend_port);
    if (backend < 0) {
      SSL_free(ssl);
      close(cfd);
      continue;
    }
    struct Relay *r = (struct Relay *)malloc(sizeof(*r));
    r->ssl = ssl;
    r->backend = backend;
    pthread_t t1, t2;
    pthread_create(&t1, NULL, ssl_to_backend, r);
    pthread_create(&t2, NULL, backend_to_ssl, r);
    pthread_detach(t1);
    pthread_detach(t2);
  }
}
