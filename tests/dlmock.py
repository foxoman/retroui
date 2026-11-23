#!/usr/bin/env python3
"""A web server of the tests' own for `retroui/fetch`'s `downloadFile` (test_downloads):

- GET /file.bin: 3 MB of known bytes (byte i is (7 i + i // 256) mod 256); a Range
  ("bytes=N-") answered 206 with what follows N
- GET /redirect: 302 to /file.bin
- GET /missing: 404
- GET /slow: 64 KB every half second, for a minute (a download to stop or cancel)

    python3 dlmock.py [port]       (0 or none: any free port, said on the first line)
"""
import http.server
import sys
import time

DATA = bytes((i * 7 + (i >> 8)) & 255 for i in range(3 * 1024 * 1024))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/file.bin")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/slow":
            self.send_response(200)
            self.send_header("Content-Length", str(65536 * 120))
            self.end_headers()
            try:
                for _ in range(120):
                    self.wfile.write(b"x" * 65536)
                    self.wfile.flush()
                    time.sleep(0.5)
            except OSError:
                pass
            return
        if self.path == "/file.bin":
            rng = self.headers.get("Range", "")
            if rng.startswith("bytes="):
                start = int(rng[6:].split("-")[0])
                body = DATA[start:]
                self.send_response(206)
                self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(DATA) - 1, len(DATA)))
            else:
                body = DATA
                self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Length", "3")
        self.end_headers()
        self.wfile.write(b"no\n")


server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
