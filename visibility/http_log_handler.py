#!/usr/bin/env python3
"""No-op proxy handler: record HTTP transactions, return {} (no mutation)."""
from __future__ import annotations

import argparse
import datetime
import http.server
import json
import os
import sys


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _header(headers: dict, name: str) -> str:
    if not isinstance(headers, dict):
        return ""
    want = name.lower()
    for key, val in headers.items():
        if str(key).lower() == want:
            if isinstance(val, list) and val:
                return str(val[0])
            return str(val)
    return ""


class HttpLogHandler(http.server.BaseHTTPRequestHandler):
    log_path = "/tmp/t9-proxy/http.log"

    def do_GET(self) -> None:
        if self.path in ("/health", "/", "/status"):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode("utf-8", errors="replace") if length else ""
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {}

        request = data.get("request") or {}
        response = data.get("response") or {}
        meta = data.get("meta") or {}
        req_headers = request.get("headers") or {}
        host = _header(req_headers, "Host")
        event = {
            "event_type": "HTTP_TRANSACTION",
            "timestamp_utc": _now(),
            "rule_name": data.get("rule_name", ""),
            "phase": "RESPONSE" if response else "REQUEST",
            "method": request.get("method", ""),
            "host": host,
            "path": request.get("path", ""),
            "status": response.get("status") if response else None,
            "client_addr": meta.get("client_addr", ""),
            "server_addr": meta.get("server_addr", ""),
            "request_id": meta.get("request_id", ""),
            "request_headers": req_headers,
            "response_headers": response.get("headers") or {},
        }
        line = json.dumps(event, separators=(",", ":"))
        os.makedirs(os.path.dirname(os.path.abspath(self.log_path)) or ".", exist_ok=True)
        with open(self.log_path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")

        body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser(description="Proxy HTTP log handler (no mutations)")
    parser.add_argument("--listen", default="127.0.0.1:8091")
    parser.add_argument("--log-file", default="/tmp/t9-proxy/http.log")
    args = parser.parse_args()
    host, _, port_s = args.listen.rpartition(":")
    if not host:
        host = "127.0.0.1"
    HttpLogHandler.log_path = args.log_file
    server = http.server.ThreadingHTTPServer((host, int(port_s)), HttpLogHandler)
    print(f"[http_log_handler] listen={args.listen} log={args.log_file}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
