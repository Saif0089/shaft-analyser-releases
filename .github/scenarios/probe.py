"""Small probes for the release CI scenarios (no proxy, short timeouts; stdlib only).

  probe.py ours <workspace>      one line per port 8765..8784 whose Shaft Analyser serves <workspace>: "<port> <version>"
  probe.py all                   one line per port 8765..8784 that answers /api/health: "<port> <workspace>"
  probe.py version <port>        the version that port serves (exit 1 if none)
  probe.py page <port>           exit 0 when / is the app's page
  probe.py field <json file> <key>[.<key>...]   one value of a JSON file ('' when missing)
  probe.py watch <status.json> <state> <latest> <s>   until status.json has that state and latest; prints its message
  probe.py listen <port>         a foreign program: an HTTP server on 127.0.0.1:<port> that answers 404 to everything
"""
import concurrent.futures
import http.server
import json
import os
import sys
import time
import urllib.request

OPEN = urllib.request.build_opener(urllib.request.ProxyHandler({}))
PORTS = range(8765, 8785)


def get(port, path, timeout=3):
    with OPEN.open("http://127.0.0.1:%d%s" % (port, path), timeout=timeout) as r:
        return r.read()


def health(port):
    try:
        h = json.loads(get(port, "/api/health"))
        return h.get("workspace") if h.get("ok") else None
    except Exception:
        return None


def scan():
    """{port: workspace} of every Shaft Analyser on 8765..8784, probed side by side (on Windows a closed port takes
    about 2 s to refuse)"""
    with concurrent.futures.ThreadPoolExecutor(len(PORTS)) as ex:
        return {p: ws for p, ws in zip(PORTS, ex.map(health, PORTS)) if ws}


def norm(p):
    return os.path.normcase(os.path.realpath(os.path.abspath(p)))


def version(port):
    try:
        return json.loads(get(port, "/api/version")).get("version", "")
    except Exception:
        return ""


cmd = sys.argv[1]
if cmd == "ours":
    want = norm(sys.argv[2])
    for p, ws in sorted(scan().items()):
        if norm(ws) == want:
            print(p, version(p))
elif cmd == "all":
    for p, ws in sorted(scan().items()):
        print(p, ws)
elif cmd == "version":
    v = version(int(sys.argv[2]))
    print(v)
    sys.exit(0 if v else 1)
elif cmd == "page":
    try:
        sys.exit(0 if b"Shaft Analyser" in get(int(sys.argv[2]), "/") else 1)
    except Exception:
        sys.exit(1)
elif cmd == "field":
    try:
        v = json.load(open(sys.argv[2], encoding="utf-8"))
        for k in sys.argv[3].split("."):
            v = v.get(k) if isinstance(v, dict) else None
        print("" if v is None else v)
    except Exception:
        print("")
elif cmd == "watch":   # watch <status.json> <state> <latest> <seconds>: until it says so; prints its message
    end = time.time() + float(sys.argv[5])
    while time.time() < end:
        try:
            st = json.load(open(sys.argv[2], encoding="utf-8"))
            if st.get("state") == sys.argv[3] and st.get("latest") == sys.argv[4]:
                print(st.get("message", ""))
                sys.exit(0)
        except Exception:
            pass
        time.sleep(0.1)
    sys.exit(1)
elif cmd == "listen":
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *a):
            pass
    http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
else:
    sys.exit("unknown probe " + cmd)
