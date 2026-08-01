/*
 * Lean 4 FFI for in-process OpenSSL TLS + ALPN h2.
 * Also provides small HTTPS/HTTP helpers used by ADC (Phase 2).
 */
#include <lean/lean.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define LEAN_GRPC_HTTP_MAX_RESP (256u * 1024u)

typedef struct {
  SSL *ssl;
  SSL_CTX *ctx;
  int fd;
} lean_grpc_ssl_conn;

typedef struct {
  SSL_CTX *ctx;
  int fd;
} lean_grpc_ssl_listener;

static void ssl_conn_finalize(void *p) {
  lean_grpc_ssl_conn *c = (lean_grpc_ssl_conn *)p;
  if (!c) return;
  if (c->ssl) {
    SSL_shutdown(c->ssl);
    SSL_free(c->ssl);
  }
  if (c->ctx) SSL_CTX_free(c->ctx);
  if (c->fd >= 0) close(c->fd);
  free(c);
}

static void ssl_listener_finalize(void *p) {
  lean_grpc_ssl_listener *l = (lean_grpc_ssl_listener *)p;
  if (!l) return;
  if (l->ctx) SSL_CTX_free(l->ctx);
  if (l->fd >= 0) close(l->fd);
  free(l);
}

static void noop_foreach(void *p, b_lean_obj_arg a) {
  (void)p;
  (void)a;
}

static lean_external_class *g_ssl_conn_class = NULL;
static lean_external_class *g_ssl_listener_class = NULL;

static lean_external_class *ssl_conn_class(void) {
  if (!g_ssl_conn_class)
    g_ssl_conn_class = lean_register_external_class(ssl_conn_finalize, noop_foreach);
  return g_ssl_conn_class;
}

static lean_external_class *ssl_listener_class(void) {
  if (!g_ssl_listener_class)
    g_ssl_listener_class = lean_register_external_class(ssl_listener_finalize, noop_foreach);
  return g_ssl_listener_class;
}

static int alpn_select(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                       const unsigned char *in, unsigned int inlen, void *arg) {
  (void)ssl;
  (void)arg;
  if (SSL_select_next_proto((unsigned char **)out, outlen,
                            (const unsigned char *)"\x02h2", 3, in, inlen) == OPENSSL_NPN_NEGOTIATED)
    return SSL_TLSEXT_ERR_OK;
  return SSL_TLSEXT_ERR_NOACK;
}

static void openssl_once_impl(void) {
  SSL_library_init();
  SSL_load_error_strings();
  OpenSSL_add_all_algorithms();
}

static void openssl_once(void) {
  static pthread_once_t once = PTHREAD_ONCE_INIT;
  pthread_once(&once, openssl_once_impl);
}

static int has_crlf(const char *s) {
  if (!s) return 0;
  for (; *s; ++s)
    if (*s == '\r' || *s == '\n') return 1;
  return 0;
}

/* Extra headers may be zero or more `Name: value\r\n` lines (no blank line / smuggling). */
static int bad_extra_headers(const char *s) {
  if (!s || !s[0]) return 0;
  const char *p = s;
  while (*p) {
    const char *line = p;
    while (*p && *p != '\r' && *p != '\n') ++p;
    if (p == line) return 1; /* empty line / smuggling */
    if (*p != '\r' || p[1] != '\n') return 1;
    p += 2;
  }
  return 0;
}

/* Configure client verify: system CAs (or caPath), peer+hostname; insecure disables verify. */
static int tls_client_setup_verify(SSL_CTX *ctx, SSL *ssl, const char *ca, const char *host_for_name,
                                   int insecure) {
  if (insecure) {
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    return 1;
  }
  if (ca && ca[0]) {
    if (!SSL_CTX_load_verify_locations(ctx, ca, NULL)) return 0;
  } else {
    if (!SSL_CTX_set_default_verify_paths(ctx)) return 0;
  }
  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  if (host_for_name && host_for_name[0]) {
    if (SSL_set1_host(ssl, host_for_name) != 1) return 0;
  }
  return 1;
}

static int http_append(char **body, size_t *cap, size_t *len, const char *buf, size_t r) {
  if (*len + r + 1 > LEAN_GRPC_HTTP_MAX_RESP) return -1;
  if (*len + r + 1 > *cap) {
    size_t ncap = *cap ? *cap * 2 : 8192;
    while (ncap < *len + r + 1) ncap *= 2;
    if (ncap > LEAN_GRPC_HTTP_MAX_RESP) ncap = LEAN_GRPC_HTTP_MAX_RESP;
    char *nb = (char *)realloc(*body, ncap);
    if (!nb) return -2;
    *body = nb;
    *cap = ncap;
  }
  memcpy(*body + *len, buf, r);
  *len += r;
  return 0;
}

static int tcp_connect(const char *host, uint16_t port) {
  char portbuf[16];
  snprintf(portbuf, sizeof(portbuf), "%u", (unsigned)port);
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *res = NULL;
  if (getaddrinfo(host, portbuf, &hints, &res) != 0 || !res) return -1;
  int fd = -1;
  for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) continue;
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
    close(fd);
    fd = -1;
  }
  freeaddrinfo(res);
  return fd;
}

static lean_obj_res io_error(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

LEAN_EXPORT lean_obj_res lean_grpc_tls_dial(b_lean_obj_arg host_obj, uint16_t port,
                                           b_lean_obj_arg ca_obj, b_lean_obj_arg sni_obj,
                                           b_lean_obj_arg cert_obj, b_lean_obj_arg key_obj,
                                           uint8_t insecure, lean_obj_arg world) {
  (void)world;
  openssl_once();
  const char *host = lean_string_cstr(host_obj);
  const char *ca = lean_string_cstr(ca_obj);
  const char *sni = lean_string_cstr(sni_obj);
  const char *cert = lean_string_cstr(cert_obj);
  const char *key = lean_string_cstr(key_obj);
  int fd = tcp_connect(host, port);
  if (fd < 0) return io_error("tls dial: connect failed");

  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (!ctx) {
    close(fd);
    return io_error("tls dial: SSL_CTX_new failed");
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_alpn_protos(ctx, (const unsigned char *)"\x02h2", 3);
  /* mTLS: present a client certificate/key when the caller supplies one. */
  if (cert && cert[0] && key && key[0]) {
    if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_check_private_key(ctx) != 1) {
      SSL_CTX_free(ctx);
      close(fd);
      return io_error("tls dial: load client cert/key failed");
    }
  }

  SSL *ssl = SSL_new(ctx);
  if (!ssl) {
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("tls dial: SSL_new failed");
  }
  SSL_set_fd(ssl, fd);
  const char *name = (sni && sni[0]) ? sni : host;
  if (name && name[0]) SSL_set_tlsext_host_name(ssl, name);
  if (!tls_client_setup_verify(ctx, ssl, ca, name, insecure ? 1 : 0)) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("tls dial: verify setup failed");
  }
  if (SSL_connect(ssl) != 1) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("tls dial: SSL_connect failed");
  }

  lean_grpc_ssl_conn *c = (lean_grpc_ssl_conn *)malloc(sizeof(*c));
  if (!c) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("tls dial: oom");
  }
  c->ssl = ssl;
  c->ctx = ctx;
  c->fd = fd;
  return lean_io_result_mk_ok(lean_alloc_external(ssl_conn_class(), c));
}

LEAN_EXPORT lean_obj_res lean_grpc_tls_listen(uint16_t port, b_lean_obj_arg cert_obj,
                                             b_lean_obj_arg key_obj, b_lean_obj_arg client_ca_obj,
                                             lean_obj_arg world) {
  (void)world;
  openssl_once();
  const char *cert = lean_string_cstr(cert_obj);
  const char *key = lean_string_cstr(key_obj);
  const char *client_ca = lean_string_cstr(client_ca_obj);
  SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) return io_error("tls listen: SSL_CTX_new failed");
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL_CTX_set_alpn_select_cb(ctx, alpn_select, NULL);
  if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) != 1 ||
      SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) != 1 ||
      SSL_CTX_check_private_key(ctx) != 1) {
    SSL_CTX_free(ctx);
    return io_error("tls listen: load cert/key failed");
  }
  /* mTLS: require and verify a client certificate signed by client_ca. */
  if (client_ca && client_ca[0]) {
    if (!SSL_CTX_load_verify_locations(ctx, client_ca, NULL)) {
      SSL_CTX_free(ctx);
      return io_error("tls listen: load client CA failed");
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, NULL);
  }
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    SSL_CTX_free(ctx);
    return io_error("tls listen: socket failed");
  }
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(port);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 128) < 0) {
    close(fd);
    SSL_CTX_free(ctx);
    return io_error("tls listen: bind/listen failed");
  }
  lean_grpc_ssl_listener *l = (lean_grpc_ssl_listener *)malloc(sizeof(*l));
  if (!l) {
    close(fd);
    SSL_CTX_free(ctx);
    return io_error("tls listen: oom");
  }
  l->ctx = ctx;
  l->fd = fd;
  return lean_io_result_mk_ok(lean_alloc_external(ssl_listener_class(), l));
}

LEAN_EXPORT lean_obj_res lean_grpc_tls_accept(b_lean_obj_arg listener_obj, lean_obj_arg world) {
  (void)world;
  lean_grpc_ssl_listener *l = (lean_grpc_ssl_listener *)lean_get_external_data(listener_obj);
  if (!l) return io_error("tls accept: bad listener");
  int cfd = accept(l->fd, NULL, NULL);
  if (cfd < 0) return io_error("tls accept: accept failed");
  SSL *ssl = SSL_new(l->ctx);
  if (!ssl) {
    close(cfd);
    return io_error("tls accept: SSL_new failed");
  }
  SSL_set_fd(ssl, cfd);
  if (SSL_accept(ssl) != 1) {
    SSL_free(ssl);
    close(cfd);
    return io_error("tls accept: SSL_accept failed");
  }
  lean_grpc_ssl_conn *c = (lean_grpc_ssl_conn *)malloc(sizeof(*c));
  if (!c) {
    SSL_free(ssl);
    close(cfd);
    return io_error("tls accept: oom");
  }
  c->ssl = ssl;
  c->ctx = NULL; /* owned by listener */
  c->fd = cfd;
  return lean_io_result_mk_ok(lean_alloc_external(ssl_conn_class(), c));
}

LEAN_EXPORT lean_obj_res lean_grpc_tls_send(b_lean_obj_arg conn_obj, b_lean_obj_arg bytes_obj,
                                           lean_obj_arg world) {
  (void)world;
  lean_grpc_ssl_conn *c = (lean_grpc_ssl_conn *)lean_get_external_data(conn_obj);
  if (!c || !c->ssl) return io_error("tls send: bad conn");
  size_t n = lean_sarray_size(bytes_obj);
  const uint8_t *p = lean_sarray_cptr((lean_object *)bytes_obj);
  size_t off = 0;
  while (off < n) {
    int w = SSL_write(c->ssl, p + off, (int)(n - off > 16384 ? 16384 : n - off));
    if (w <= 0) return io_error("tls send: SSL_write failed");
    off += (size_t)w;
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_grpc_tls_recv(b_lean_obj_arg conn_obj, lean_obj_arg max_obj,
                                           lean_obj_arg world) {
  (void)world;
  lean_grpc_ssl_conn *c = (lean_grpc_ssl_conn *)lean_get_external_data(conn_obj);
  if (!c || !c->ssl) return io_error("tls recv: bad conn");
  size_t max = lean_unbox(max_obj);
  if (max == 0) max = 65536;
  if (max > 1024 * 1024) max = 1024 * 1024;
  lean_object *buf = lean_alloc_sarray(1, 0, max);
  uint8_t *p = lean_sarray_cptr(buf);
  int n = SSL_read(c->ssl, p, (int)max);
  if (n <= 0) {
    lean_dec(buf);
    /* none */
    return lean_io_result_mk_ok(lean_box(0));
  }
  lean_sarray_set_size(buf, (size_t)n);
  lean_object *some = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(some, 0, buf);
  return lean_io_result_mk_ok(some);
}

LEAN_EXPORT lean_obj_res lean_grpc_tls_close(b_lean_obj_arg conn_obj, lean_obj_arg world) {
  (void)world;
  lean_grpc_ssl_conn *c = (lean_grpc_ssl_conn *)lean_get_external_data(conn_obj);
  if (c && c->ssl) {
    SSL_shutdown(c->ssl);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

/* ---- ADC helpers (Phase 2) ---- */

static lean_obj_res mk_byte_array(const uint8_t *data, size_t n) {
  lean_object *buf = lean_alloc_sarray(1, n, n);
  memcpy(lean_sarray_cptr(buf), data, n);
  return buf;
}

LEAN_EXPORT lean_obj_res lean_grpc_rsa_sign_sha256(b_lean_obj_arg pem_obj, b_lean_obj_arg msg_obj,
                                                  lean_obj_arg world) {
  (void)world;
  openssl_once();
  const char *pem = lean_string_cstr(pem_obj);
  BIO *bio = BIO_new_mem_buf(pem, -1);
  if (!bio) return io_error("rsa sign: bio");
  EVP_PKEY *key = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
  BIO_free(bio);
  if (!key) return io_error("rsa sign: bad PEM key");
  EVP_MD_CTX *md = EVP_MD_CTX_new();
  if (!md) {
    EVP_PKEY_free(key);
    return io_error("rsa sign: md ctx");
  }
  size_t msg_len = lean_sarray_size(msg_obj);
  const uint8_t *msg = lean_sarray_cptr((lean_object *)msg_obj);
  if (EVP_DigestSignInit(md, NULL, EVP_sha256(), NULL, key) != 1 ||
      EVP_DigestSignUpdate(md, msg, msg_len) != 1) {
    EVP_MD_CTX_free(md);
    EVP_PKEY_free(key);
    return io_error("rsa sign: init/update failed");
  }
  size_t sig_len = 0;
  if (EVP_DigestSignFinal(md, NULL, &sig_len) != 1) {
    EVP_MD_CTX_free(md);
    EVP_PKEY_free(key);
    return io_error("rsa sign: size failed");
  }
  uint8_t *sig = (uint8_t *)malloc(sig_len);
  if (!sig) {
    EVP_MD_CTX_free(md);
    EVP_PKEY_free(key);
    return io_error("rsa sign: oom");
  }
  if (EVP_DigestSignFinal(md, sig, &sig_len) != 1) {
    free(sig);
    EVP_MD_CTX_free(md);
    EVP_PKEY_free(key);
    return io_error("rsa sign: final failed");
  }
  EVP_MD_CTX_free(md);
  EVP_PKEY_free(key);
  lean_object *out = mk_byte_array(sig, sig_len);
  OPENSSL_cleanse(sig, sig_len);
  free(sig);
  return lean_io_result_mk_ok(out);
}

/* Minimal HTTP/1.1 GET over plain TCP (metadata server). */
LEAN_EXPORT lean_obj_res lean_grpc_http_get(b_lean_obj_arg host_obj, uint16_t port,
                                           b_lean_obj_arg path_obj, b_lean_obj_arg hdr_obj,
                                           lean_obj_arg world) {
  (void)world;
  const char *host = lean_string_cstr(host_obj);
  const char *path = lean_string_cstr(path_obj);
  const char *extra = lean_string_cstr(hdr_obj);
  if (has_crlf(path) || has_crlf(host) || bad_extra_headers(extra))
    return io_error("http get: bad path/host/headers");
  int fd = tcp_connect(host, port);
  if (fd < 0) return io_error("http get: connect failed");
  char req[4096];
  /* `extra` is zero or more `Name: value\r\n` lines; final `\r\n` ends the header block. */
  int n = snprintf(req, sizeof(req),
                   "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n%s\r\n", path, host,
                   extra);
  if (n <= 0 || n >= (int)sizeof(req) || write(fd, req, (size_t)n) != n) {
    close(fd);
    return io_error("http get: write failed");
  }
  char *body = NULL;
  size_t cap = 0, len = 0;
  char buf[4096];
  for (;;) {
    ssize_t r = read(fd, buf, sizeof(buf));
    if (r <= 0) break;
    int ap = http_append(&body, &cap, &len, buf, (size_t)r);
    if (ap != 0) {
      free(body);
      close(fd);
      return io_error(ap == -1 ? "http get: response too large" : "http get: oom");
    }
  }
  close(fd);
  if (!body) return io_error("http get: empty");
  body[len] = 0;
  char *hdr_end = strstr(body, "\r\n\r\n");
  const char *payload = hdr_end ? hdr_end + 4 : body;
  lean_object *out = lean_mk_string(payload);
  free(body);
  return lean_io_result_mk_ok(out);
}

/* Plain HTTP/1.1 POST (CI token mock). */
LEAN_EXPORT lean_obj_res lean_grpc_http_post(b_lean_obj_arg host_obj, uint16_t port,
                                            b_lean_obj_arg path_obj, b_lean_obj_arg body_obj,
                                            b_lean_obj_arg content_type_obj, lean_obj_arg world) {
  (void)world;
  const char *host = lean_string_cstr(host_obj);
  const char *path = lean_string_cstr(path_obj);
  const char *ctype = lean_string_cstr(content_type_obj);
  if (has_crlf(path) || has_crlf(host) || has_crlf(ctype))
    return io_error("http post: CRLF in path/host/content-type");
  size_t body_len = lean_sarray_size(body_obj);
  const uint8_t *body = lean_sarray_cptr((lean_object *)body_obj);
  int fd = tcp_connect(host, port);
  if (fd < 0) return io_error("http post: connect failed");
  char hdr[1024];
  int hn = snprintf(hdr, sizeof(hdr),
                    "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: %s\r\n"
                    "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                    path, host, ctype, body_len);
  if (hn <= 0 || hn >= (int)sizeof(hdr) || write(fd, hdr, (size_t)hn) != hn ||
      (body_len > 0 && write(fd, body, body_len) != (ssize_t)body_len)) {
    close(fd);
    return io_error("http post: write failed");
  }
  char *resp = NULL;
  size_t cap = 0, len = 0;
  char buf[4096];
  for (;;) {
    ssize_t r = read(fd, buf, sizeof(buf));
    if (r <= 0) break;
    int ap = http_append(&resp, &cap, &len, buf, (size_t)r);
    if (ap != 0) {
      free(resp);
      close(fd);
      return io_error(ap == -1 ? "http post: response too large" : "http post: oom");
    }
  }
  close(fd);
  if (!resp) return io_error("http post: empty");
  resp[len] = 0;
  char *hdr_end = strstr(resp, "\r\n\r\n");
  const char *payload = hdr_end ? hdr_end + 4 : resp;
  lean_object *out = lean_mk_string(payload);
  free(resp);
  return lean_io_result_mk_ok(out);
}

/* HTTPS POST (token exchange) — TLS with peer+hostname verify by default. */
LEAN_EXPORT lean_obj_res lean_grpc_https_post(b_lean_obj_arg host_obj, uint16_t port,
                                             b_lean_obj_arg path_obj, b_lean_obj_arg body_obj,
                                             b_lean_obj_arg content_type_obj,
                                             b_lean_obj_arg ca_obj, uint8_t insecure,
                                             lean_obj_arg world) {
  (void)world;
  openssl_once();
  const char *host = lean_string_cstr(host_obj);
  const char *path = lean_string_cstr(path_obj);
  const char *ctype = lean_string_cstr(content_type_obj);
  const char *ca = lean_string_cstr(ca_obj);
  if (has_crlf(path) || has_crlf(host) || has_crlf(ctype))
    return io_error("https post: CRLF in path/host/content-type");
  size_t body_len = lean_sarray_size(body_obj);
  const uint8_t *body = lean_sarray_cptr((lean_object *)body_obj);
  int fd = tcp_connect(host, port);
  if (fd < 0) return io_error("https post: connect failed");
  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (!ctx) {
    close(fd);
    return io_error("https post: ctx");
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  SSL *ssl = SSL_new(ctx);
  if (!ssl) {
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("https post: ssl");
  }
  SSL_set_fd(ssl, fd);
  SSL_set_tlsext_host_name(ssl, host);
  if (!tls_client_setup_verify(ctx, ssl, ca, host, insecure ? 1 : 0)) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("https post: verify setup failed");
  }
  if (SSL_connect(ssl) != 1) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("https post: handshake");
  }
  char hdr[1024];
  int hn = snprintf(hdr, sizeof(hdr),
                    "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: %s\r\n"
                    "Content-Length: %zu\r\nConnection: close\r\n\r\n",
                    path, host, ctype, body_len);
  if (hn <= 0 || hn >= (int)sizeof(hdr) || SSL_write(ssl, hdr, hn) != hn ||
      (body_len > 0 && SSL_write(ssl, body, (int)body_len) != (int)body_len)) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return io_error("https post: write");
  }
  char *resp = NULL;
  size_t cap = 0, len = 0;
  char buf[4096];
  for (;;) {
    int r = SSL_read(ssl, buf, sizeof(buf));
    if (r <= 0) break;
    int ap = http_append(&resp, &cap, &len, buf, (size_t)r);
    if (ap != 0) {
      free(resp);
      SSL_free(ssl);
      SSL_CTX_free(ctx);
      close(fd);
      return io_error(ap == -1 ? "https post: response too large" : "https post: oom");
    }
  }
  SSL_free(ssl);
  SSL_CTX_free(ctx);
  close(fd);
  if (!resp) return io_error("https post: empty");
  resp[len] = 0;
  char *hdr_end = strstr(resp, "\r\n\r\n");
  const char *payload = hdr_end ? hdr_end + 4 : resp;
  lean_object *out = lean_mk_string(payload);
  free(resp);
  return lean_io_result_mk_ok(out);
}
