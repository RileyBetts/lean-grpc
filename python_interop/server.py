#!/usr/bin/env python3
"""Minimal Python gRPC interop server for Lean client → Python tests."""
from __future__ import annotations

import argparse
import time
from concurrent import futures
from typing import Iterator

import grpc

import empty_pb2
import messages_pb2
import test_pb2_grpc


def _zeros(n: int) -> bytes:
    return b"\x00" * n


def _grpc_status(code: int) -> grpc.StatusCode:
    """Map wire status int → grpc.StatusCode (enum values are nested tuples)."""
    for c in grpc.StatusCode:
        if c.value[0].value == code:
            return c
    return grpc.StatusCode.UNKNOWN


class TestService(test_pb2_grpc.TestServiceServicer):
    def EmptyCall(self, request, context):  # noqa: N802
        self._echo_md(context)
        return empty_pb2.Empty()

    def UnaryCall(self, request, context):  # noqa: N802
        self._echo_md(context)
        if request.HasField("expect_compressed"):
            # Best-effort: grpc Python doesn't expose compressed-flag easily here.
            pass
        if request.HasField("response_status"):
            context.set_code(_grpc_status(request.response_status.code))
            context.set_details(request.response_status.message)
            return messages_pb2.SimpleResponse()
        username = ""
        oauth = ""
        if request.fill_username:
            md = dict(context.invocation_metadata())
            auth = md.get("authorization", "")
            username = auth[7:] if auth.lower().startswith("bearer ") else (auth or "python")
        if request.fill_oauth_scope:
            oauth = "https://www.googleapis.com/auth/xapi.zoo"
        body = _zeros(request.response_size)
        return messages_pb2.SimpleResponse(
            payload=messages_pb2.Payload(body=body),
            username=username,
            oauth_scope=oauth,
        )

    def StreamingOutputCall(self, request, context):  # noqa: N802
        self._echo_md(context)
        for p in request.response_parameters:
            yield messages_pb2.StreamingOutputCallResponse(
                payload=messages_pb2.Payload(body=_zeros(p.size))
            )

    def StreamingInputCall(self, request_iterator, context):  # noqa: N802
        self._echo_md(context)
        total = 0
        for req in request_iterator:
            total += len(req.payload.body)
        return messages_pb2.StreamingInputCallResponse(aggregated_payload_size=total)

    def FullDuplexCall(self, request_iterator, context):  # noqa: N802
        self._echo_md(context)
        for req in request_iterator:
            if req.HasField("response_status"):
                if req.response_status.message == "sleep":
                    time.sleep(2.0)
                else:
                    context.set_code(_grpc_status(req.response_status.code))
                    context.set_details(req.response_status.message)
                    return
            for p in req.response_parameters:
                yield messages_pb2.StreamingOutputCallResponse(
                    payload=messages_pb2.Payload(body=_zeros(p.size))
                )

    def HalfDuplexCall(self, request_iterator, context):  # noqa: N802
        return self.FullDuplexCall(request_iterator, context)

    def UnimplementedCall(self, request, context):  # noqa: N802
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details("unimplemented")
        return empty_pb2.Empty()

    @staticmethod
    def _echo_md(context: grpc.ServicerContext) -> None:
        init = []
        trailing = []
        for k, v in context.invocation_metadata():
            if k == "x-grpc-test-echo-initial":
                init.append((k, v))
            if k == "x-grpc-test-echo-trailing-bin":
                trailing.append((k, v))
        if init:
            context.send_initial_metadata(init)
        if trailing:
            context.set_trailing_metadata(trailing)


class UnimplementedService(test_pb2_grpc.UnimplementedServiceServicer):
    def UnimplementedCall(self, request, context):  # noqa: N802
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details("unimplemented")
        return empty_pb2.Empty()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=10001)
    args = p.parse_args()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    test_pb2_grpc.add_TestServiceServicer_to_server(TestService(), server)
    test_pb2_grpc.add_UnimplementedServiceServicer_to_server(
        UnimplementedService(), server
    )
    server.add_insecure_port(f"127.0.0.1:{args.port}")
    server.start()
    print(f"python interop server on 127.0.0.1:{args.port}", flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
