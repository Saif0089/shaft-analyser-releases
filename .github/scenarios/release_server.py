"""github.com's release links for one release, served on 127.0.0.1 (release CI scenarios).

  python -I release_server.py <dist dir> <tag> <port> [--mode MODE] [--gate FILE] [--log FILE]

  HEAD/GET /latest                 -> 302 /tag/<tag>   (404 while --gate FILE does not exist)
  /download/<tag>/<file>           -> 302 /files/<file>  (github.com sends files from another host)
  /files/<file>                    -> 200 the file, or what MODE makes of it:
     ok        the file as built
     truncate  every .zip and launcher binary: the headers announce the whole file, half of it is sent, then the
               connection closes (a download cut off half way)
     flip      every .zip and launcher binary: one byte in the middle changed (fails its checksum)
     html      every file, checksums.txt included: 200 text/html, a proxy's login page
An installer is pointed at http://127.0.0.1:<port>/download/<tag> (SHAFT_RELEASE_URL), a launcher at
http://127.0.0.1:<port> (SHAFT_UPDATE_BASE).
"""
import argparse
import http.server
import os
import time

ap = argparse.ArgumentParser()
ap.add_argument("dist")
ap.add_argument("tag")
ap.add_argument("port", type=int)
ap.add_argument("--mode", default="ok", choices=["ok", "truncate", "flip", "html"])
ap.add_argument("--gate")
ap.add_argument("--log")
a = ap.parse_args()
BASE = "http://127.0.0.1:%d" % a.port
HTML = b"<!doctype html><html><body><h1>Proxy authentication required</h1><form>Login</form></body></html>\n"


def payload(name):
    with open(os.path.join(a.dist, name), "rb") as f:
        data = f.read()
    big = name.endswith(".zip") or name.startswith("shaft-analyser-")
    if a.mode == "html":
        return HTML, len(HTML), "text/html"
    if a.mode == "flip" and big:
        b = bytearray(data)
        b[len(b) // 2] ^= 0xFF
        return bytes(b), len(b), "application/octet-stream"
    if a.mode == "truncate" and big:
        return data[: len(data) // 2], len(data), "application/octet-stream"
    return data, len(data), "application/octet-stream"


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if a.log:
            with open(a.log, "a") as f:
                f.write(time.strftime("%H:%M:%S ") + (fmt % args) + "\n")

    def empty(self, code, loc=None):
        self.send_response(code)
        if loc:
            self.send_header("Location", loc)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def route(self, body):
        p = self.path.split("?")[0]
        dl, fl = "/download/%s/" % a.tag, "/files/"
        files = set(os.listdir(a.dist))
        if p == "/latest":
            if a.gate and not os.path.exists(a.gate):
                return self.empty(404)
            return self.empty(302, BASE + "/tag/" + a.tag)
        if p.startswith(dl) and p[len(dl):] in files:
            return self.empty(302, BASE + fl + p[len(dl):])
        if p.startswith(fl) and p[len(fl):] in files:
            data, length, ctype = payload(p[len(fl):])
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            if len(data) < length:
                self.send_header("Connection", "close")
            self.end_headers()
            if body:
                self.wfile.write(data)
                if len(data) < length:
                    self.wfile.flush()
                    self.close_connection = True
            return
        return self.empty(404)

    def do_HEAD(self):
        self.route(False)

    def do_GET(self):
        self.route(True)


http.server.ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()
