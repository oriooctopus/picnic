#!/usr/bin/env python3
"""Throwaway local stand-in for the real picnic-mirror server (server/, owned
by another agent). Useful for manually exercising MirrorClient/MirrorQueueStore
against a simulator build without needing the real Tailscale endpoint.

Usage: python3 mock_mirror_server.py [port]   (default 8307)
Logs every POST /queue body to stdout; requires "Authorization: Bearer <any>".
"""
import http.server
import json
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/queue":
            self.send_response(404)
            self.end_headers()
            return
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self.send_response(401)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return
        print("received:", json.dumps(payload), flush=True)
        self.send_response(200)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8307
    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    print(f"mock mirror server on 127.0.0.1:{port}", flush=True)
    server.serve_forever()
