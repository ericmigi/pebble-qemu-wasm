#!/usr/bin/env python3
"""Dev server with COOP/COEP headers required for SharedArrayBuffer (Emscripten pthreads)."""

import http.server
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else "."


class COOPCOEPHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    with ThreadedHTTPServer(("", PORT), COOPCOEPHandler) as httpd:
        print(f"Serving {DIRECTORY}/ at http://localhost:{PORT}")
        print("COOP/COEP headers enabled (SharedArrayBuffer support)")
        httpd.serve_forever()
