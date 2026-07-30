# Conformance & interop

## Unit tests

```bash
lake build bytesTests hpackTests h2Tests grpcTests
./.lake/build/bin/bytesTests && ./.lake/build/bin/hpackTests && \
  ./.lake/build/bin/h2Tests && ./.lake/build/bin/grpcTests
```

## h2spec

Build an h2c server that accepts connections (helloworld or a dedicated fixture), then:

```bash
h2spec -p 50051 -h 127.0.0.1
```

Track results in CI artifacts. Full green h2spec is a Phase 2 exit criterion; expand server behavior as failures appear.

## Official gRPC interop

```bash
lake build interopServer interopClient
./.lake/build/bin/interopServer &
./.lake/build/bin/interopClient 127.0.0.1 10000 empty_unary
./.lake/build/bin/interopClient 127.0.0.1 10000 large_unary
```

Docker (reference clients against Lean server):

```bash
docker run --rm --network host grpc/go \
  /go/bin/client --server_host=127.0.0.1 --server_port=10000 --use_tls=false --test_case=empty_unary
```

## Benchmarks

```bash
lake build helloworldServer benchUnary
./.lake/build/bin/helloworldServer &
./.lake/build/bin/benchUnary 127.0.0.1 50051 200
```

Compare later against a tonic peer on the same host; record p50/p99 in CI once baselines exist.
