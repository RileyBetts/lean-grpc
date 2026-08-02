#!/usr/bin/env python3
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
"""Python gRPC interop client (same non-auth cases as the Go stock client)."""
from __future__ import annotations

import argparse
import sys
import time
from typing import Iterator

import grpc

import empty_pb2
import messages_pb2
import test_pb2_grpc

LARGE_REQ = 271828
LARGE_RESP = 314159


def _zeros(n: int) -> bytes:
    return b"\x00" * n


def _payload(n: int) -> messages_pb2.Payload:
    return messages_pb2.Payload(body=_zeros(n))


def run_case(
    channel: grpc.Channel, stub: test_pb2_grpc.TestServiceStub, case: str
) -> None:
    if case == "empty_unary":
        stub.EmptyCall(empty_pb2.Empty())

    elif case == "large_unary":
        resp = stub.UnaryCall(
            messages_pb2.SimpleRequest(
                response_size=LARGE_RESP,
                payload=_payload(LARGE_REQ),
            )
        )
        assert len(resp.payload.body) == LARGE_RESP, len(resp.payload.body)

    elif case == "status_code_and_message":
        try:
            stub.UnaryCall(
                messages_pb2.SimpleRequest(
                    response_status=messages_pb2.EchoStatus(
                        code=2, message="test status message"
                    )
                )
            )
            raise AssertionError("expected RPC error")
        except grpc.RpcError as e:
            assert e.code() == grpc.StatusCode.UNKNOWN, e.code()
            assert e.details() == "test status message", e.details()

    elif case == "special_status_message":
        msg = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
        try:
            stub.UnaryCall(
                messages_pb2.SimpleRequest(
                    response_status=messages_pb2.EchoStatus(code=2, message=msg)
                )
            )
            raise AssertionError("expected RPC error")
        except grpc.RpcError as e:
            assert e.code() == grpc.StatusCode.UNKNOWN, e.code()
            assert e.details() == msg, repr(e.details())

    elif case == "custom_metadata":
        md = (
            ("x-grpc-test-echo-initial", "test_initial_metadata_value"),
            (
                "x-grpc-test-echo-trailing-bin",
                bytes([0x0A, 0x0B, 0x0A, 0x0B, 0x0A, 0x0B]),
            ),
        )
        fut = stub.UnaryCall.future(
            messages_pb2.SimpleRequest(response_size=1, payload=_payload(1)),
            metadata=md,
        )
        fut.result()
        uh = dict(fut.initial_metadata())
        ut = dict(fut.trailing_metadata())
        assert uh.get("x-grpc-test-echo-initial") == "test_initial_metadata_value"
        assert "x-grpc-test-echo-trailing-bin" in ut

        def gen() -> Iterator[messages_pb2.StreamingOutputCallRequest]:
            yield messages_pb2.StreamingOutputCallRequest(
                response_parameters=[messages_pb2.ResponseParameters(size=1)],
                payload=_payload(1),
            )

        stream = stub.FullDuplexCall(gen(), metadata=md)
        headers = dict(stream.initial_metadata())
        next(stream)
        for _ in stream:
            pass
        trailers = dict(stream.trailing_metadata())
        assert headers.get("x-grpc-test-echo-initial") == "test_initial_metadata_value"
        assert "x-grpc-test-echo-trailing-bin" in trailers

    elif case == "cancel_after_begin":
        def gen() -> Iterator[messages_pb2.StreamingInputCallRequest]:
            time.sleep(60)
            if False:  # pragma: no cover
                yield messages_pb2.StreamingInputCallRequest()

        call = stub.StreamingInputCall.future(gen())
        time.sleep(0.05)
        call.cancel()
        try:
            call.result()
            raise AssertionError("expected cancelled future")
        except grpc.FutureCancelledError:
            pass
        except grpc.RpcError as e:
            assert e.code() in (
                grpc.StatusCode.CANCELLED,
                grpc.StatusCode.UNKNOWN,
            ), e.code()

    elif case == "cancel_after_first_response":
        q: list[messages_pb2.StreamingOutputCallRequest] = [
            messages_pb2.StreamingOutputCallRequest(
                response_parameters=[messages_pb2.ResponseParameters(size=31415)]
            )
        ]

        def gen() -> Iterator[messages_pb2.StreamingOutputCallRequest]:
            yield q[0]
            while True:
                time.sleep(0.1)
                yield messages_pb2.StreamingOutputCallRequest()

        stream = stub.FullDuplexCall(gen())
        next(stream)
        stream.cancel()

    elif case == "server_streaming":
        sizes = [31415, 9, 2653, 58979]
        resp = stub.StreamingOutputCall(
            messages_pb2.StreamingOutputCallRequest(
                response_parameters=[
                    messages_pb2.ResponseParameters(size=s) for s in sizes
                ]
            )
        )
        bodies = [r.payload.body for r in resp]
        assert [len(b) for b in bodies] == sizes, [len(b) for b in bodies]

    elif case == "client_streaming":
        sizes = [27182, 8, 1828, 45904]

        def gen() -> Iterator[messages_pb2.StreamingInputCallRequest]:
            for s in sizes:
                yield messages_pb2.StreamingInputCallRequest(payload=_payload(s))

        resp = stub.StreamingInputCall(gen())
        assert resp.aggregated_payload_size == sum(sizes)

    elif case == "ping_pong":
        sizes = [31415, 9, 2653, 58979]

        def gen() -> Iterator[messages_pb2.StreamingOutputCallRequest]:
            for s in sizes:
                yield messages_pb2.StreamingOutputCallRequest(
                    response_parameters=[messages_pb2.ResponseParameters(size=s)]
                )

        stream = stub.FullDuplexCall(gen())
        got = [len(r.payload.body) for r in stream]
        assert got == sizes, got

    elif case == "empty_stream":

        def gen() -> Iterator[messages_pb2.StreamingOutputCallRequest]:
            return
            yield  # pragma: no cover

        assert list(stub.FullDuplexCall(gen())) == []

    elif case == "timeout_on_sleeping_server":
        try:
            list(
                stub.FullDuplexCall(
                    iter(
                        [
                            messages_pb2.StreamingOutputCallRequest(
                                response_status=messages_pb2.EchoStatus(
                                    code=0, message="sleep"
                                )
                            )
                        ]
                    ),
                    timeout=0.1,
                )
            )
            raise AssertionError("expected deadline exceeded")
        except grpc.RpcError as e:
            assert e.code() == grpc.StatusCode.DEADLINE_EXCEEDED, e.code()

    elif case == "unimplemented_method":
        try:
            stub.UnimplementedCall(empty_pb2.Empty())
            raise AssertionError("expected unimplemented")
        except grpc.RpcError as e:
            assert e.code() == grpc.StatusCode.UNIMPLEMENTED, e.code()

    elif case == "unimplemented_service":
        bad = test_pb2_grpc.UnimplementedServiceStub(channel)
        try:
            bad.UnimplementedCall(empty_pb2.Empty())
            raise AssertionError("expected unimplemented")
        except grpc.RpcError as e:
            assert e.code() == grpc.StatusCode.UNIMPLEMENTED, e.code()

    elif case == "client_compressed_unary":
        # Per-call gzip; Lean server inflates via grpc-encoding / Compressed-Flag.
        resp = stub.UnaryCall(
            messages_pb2.SimpleRequest(
                response_size=31415,
                payload=_payload(27182),
                expect_compressed=messages_pb2.BoolValue(value=True),
            ),
            compression=grpc.Compression.Gzip,
        )
        assert len(resp.payload.body) == 31415, len(resp.payload.body)

    elif case == "server_compressed_unary":
        resp = stub.UnaryCall(
            messages_pb2.SimpleRequest(
                response_size=31415,
                payload=_payload(27182),
                response_compressed=messages_pb2.BoolValue(value=True),
            ),
            compression=grpc.Compression.Gzip,
        )
        assert len(resp.payload.body) == 31415, len(resp.payload.body)

    elif case == "server_compressed_streaming":
        sizes = [31415, 92653]
        req = messages_pb2.StreamingOutputCallRequest(
            response_parameters=[
                messages_pb2.ResponseParameters(
                    size=n, compressed=messages_pb2.BoolValue(value=True)
                )
                for n in sizes
            ]
        )
        bodies = [
            r.payload.body
            for r in stub.StreamingOutputCall(req, compression=grpc.Compression.Gzip)
        ]
        assert [len(b) for b in bodies] == sizes, [len(b) for b in bodies]

    else:
        raise SystemExit(f"unknown/unsupported python case: {case}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--server_host", default="127.0.0.1")
    p.add_argument("--server_port", type=int, default=10000)
    p.add_argument("--test_case", required=True)
    p.add_argument("--use_tls", action="store_true")
    args = p.parse_args()
    if args.use_tls:
        raise SystemExit("TLS not wired in this helper; use h2c")
    target = f"{args.server_host}:{args.server_port}"
    with grpc.insecure_channel(target) as channel:
        stub = test_pb2_grpc.TestServiceStub(channel)
        run_case(channel, stub, args.test_case)
    print(f"{args.test_case} OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
