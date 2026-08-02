#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Exercises the *real* protoc-plugin path of protoc-gen-lean4-grpc: decoding a binary
# `google.protobuf.compiler.CodeGeneratorRequest` from stdin and emitting a real
# `CodeGeneratorResponse` (message structs + typed client/server code) on stdout.
#
# `protoc` itself is not assumed to be installed (it isn't in CI), so this script hand-builds
# a minimal CodeGeneratorRequest for a tiny "helloworld"-shaped service using a small Python
# helper (stdlib only — no protobuf package required, since the wire format is simple enough
# to construct by hand). This is exactly the request protoc would send for:
#
#   syntax = "proto3";
#   package helloworld;
#   message HelloRequest { string name = 1; }
#   message HelloReply { string message = 1; }
#   service Greeter { rpc SayHello (HelloRequest) returns (HelloReply); }
#
# Usage: to run against a real protoc instead, once available:
#   protoc --plugin=protoc-gen-lean4=./.lake/build/bin/protoc-gen-lean4-grpc \
#     --lean4_out=/tmp/out -I examples examples/helloworld.proto
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
lake build protocGenLean4Grpc

REQ=/tmp/lean-grpc-codegen-fixture-request.bin
RESP=/tmp/lean-grpc-codegen-fixture-response.bin

python3 - "$REQ" <<'PY'
import sys, struct

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def tag(field, wt):
    return varint((field << 3) | wt)

def ld(field, payload: bytes):
    return tag(field, 2) + varint(len(payload)) + payload

def string(field, s: str):
    return ld(field, s.encode("utf-8"))

def varint_field(field, n: int):
    return tag(field, 0) + varint(n)

def field_descriptor(name, number, type_):
    return (string(1, name) + varint_field(3, number) + varint_field(5, type_))

def message(name, fields):
    body = string(1, name)
    for f in fields:
        body += ld(2, f)
    return body

def method(name, input_type, output_type):
    return string(1, name) + string(2, input_type) + string(3, output_type)

def service(name, methods):
    body = string(1, name)
    for m in methods:
        body += ld(2, m)
    return body

TYPE_STRING = 9

hello_request = message("HelloRequest", [field_descriptor("name", 1, TYPE_STRING)])
hello_reply = message("HelloReply", [field_descriptor("message", 1, TYPE_STRING)])
greeter = service("Greeter", [
    method("SayHello", ".helloworld.HelloRequest", ".helloworld.HelloReply"),
])

file_descriptor = (
    string(1, "helloworld.proto")
    + string(2, "helloworld")
    + ld(4, hello_request)
    + ld(4, hello_reply)
    + ld(6, greeter)
)

request = (
    string(1, "helloworld.proto")   # file_to_generate
    + ld(15, file_descriptor)       # proto_file
)

with open(sys.argv[1], "wb") as f:
    f.write(request)
PY

./.lake/build/bin/protoc-gen-lean4-grpc < "$REQ" > "$RESP"

# CodeGeneratorResponse.file[0].content is an embedded protobuf string, so its raw UTF-8
# bytes appear verbatim in the response — a plain byte-level grep is enough to check it.
for needle in "structure HelloRequest" "structure HelloReply" "GreeterStub" \
    "def SayHello" "registerGreeterSayHello"; do
  if ! grep -a -q -- "$needle" "$RESP"; then
    echo "codegen fixture: expected '$needle' in generated output ($RESP)" >&2
    exit 1
  fi
done

echo "run-codegen-fixture OK"
