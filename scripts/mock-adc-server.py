#!/usr/bin/env python3
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
"""Minimal GCE metadata + OAuth token mock for ADC CI."""
from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        pass

    def do_GET(self) -> None:  # noqa: N802
        if "Metadata-Flavor" not in self.headers and "metadata" in self.path:
            self.send_response(403)
            self.end_headers()
            return
        if "/token" in self.path or "service-accounts" in self.path:
            body = json.dumps({"access_token": "meta-fixture-token", "expires_in": 3600}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        n = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(n)
        if self.path.startswith("/token"):
            body = json.dumps({"access_token": "sa-fixture-token", "expires_in": 3600}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


def main() -> None:
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=18080)
    args = p.parse_args()
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
