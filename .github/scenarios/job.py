"""A real job through the app's API, as an engineer runs it (release CI scenarios; stdlib only, no proxy).

  job.py <port> <sample.laz> <state dir> start   new shaft, add the scan, ingest -> audit -> layout -> qc (proceed on
                                                RED), confirm the layout, segmentation; then starts the families and
                                                segmented-cloud exports and returns while they run (<state dir>/scan)
  job.py <port> <sample.laz> <state dir> finish  waits for both exports (the app may restart in between: an update),
                                                then checks they are done, not interrupted, and segmented.laz is whole

The port can change across an update only if the launcher moves; finish re-reads it from <state dir>/port when present.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

port, sample, state, step = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
OPEN = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def log(m):
    print(time.strftime("[%H:%M:%S] ") + m, flush=True)


def call(method, path, body=None, timeout=120):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request("http://127.0.0.1:%d/api%s" % (port, path), data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with OPEN.open(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw[:1] in (b"{", b"[") else raw


def scan(scid):
    try:
        return call("GET", "/scans/%s" % scid, timeout=10)
    except Exception:
        return None   # the app is restarting (an update): try again


def wait(scid, stage, minutes=30, allow_down=False):
    end, last = time.time() + 60 * minutes, 0
    while time.time() < end:
        s = scan(scid)
        if s is not None:
            for k, v in (s.get("stages") or {}).items():
                if v.get("status") in ("failed", "interrupted"):
                    sys.exit("stage %s %s: %s" % (k, v.get("status"), v.get("error") or v.get("message")))
            st = (s.get("stages") or {}).get(stage) or {}
            if st.get("status") == "done":
                log("  %s done in %s s" % (stage, st.get("seconds")))
                return st
            if time.time() - last > 30:
                last = time.time()
                log("  %s: %s %.0f %% %s" % (stage, st.get("status"), 100 * float(st.get("progress") or 0), st.get("message") or ""))
        elif not allow_down:
            pass
        time.sleep(2)
    sys.exit("%s not done after %d min" % (stage, minutes))


if step == "start":
    shaft = call("POST", "/shafts", {"name": "CI shaft (job)", "mine": "CI", "notes": ""})
    sc = call("POST", "/shafts/%s/scans" % shaft["id"], {"path": sample})
    scid = sc["id"]
    open(os.path.join(state, "scan"), "w").write(scid)
    log("shaft %s, scan %s" % (shaft["id"], scid))
    for st in ("ingest", "audit", "layout", "qc"):
        wait(scid, st)
    qc = call("GET", "/scans/%s/qc" % scid)
    log("correction check: %s" % qc.get("status"))
    if qc.get("status") == "RED":
        call("POST", "/scans/%s/decision" % scid, {"choice": "proceed", "note": "CI"})
    call("POST", "/scans/%s/layout/confirm" % scid)
    wait(scid, "segment")
    call("POST", "/scans/%s/exports/families" % scid)
    call("POST", "/scans/%s/exports/simple" % scid)
    busy = [j for j in call("GET", "/jobs") if j.get("status") in ("queued", "running")]
    log("exports started; jobs queued or running: %d" % len(busy))
    if not busy:
        sys.exit("the exports are not jobs the launcher can see (/api/jobs shows none running): an update would not wait")
elif step == "finish":
    scid = open(os.path.join(state, "scan")).read().strip()
    if os.path.exists(os.path.join(state, "port")):
        port = int(open(os.path.join(state, "port")).read().strip())
    wait(scid, "export_families", allow_down=True)
    wait(scid, "export_simple", allow_down=True)
    def retry(*a, **k):   # the app restarts once more when the update installs right after the exports
        for i in range(90):
            try:
                return call(*a, **k)
            except (urllib.error.URLError, OSError, ValueError):
                time.sleep(2)
        return call(*a, **k)
    ex = retry("GET", "/scans/%s/exports" % scid)
    files = {f["name"]: f["size"] for f in ex.get("files", [])}
    log("export files: %s" % files)
    if not files.get("segmented.laz"):
        sys.exit("segmented.laz is missing from the exports")
    data = retry("GET", "/scans/%s/exports/file/segmented.laz" % scid, timeout=300)
    if len(data) != files["segmented.laz"] or data[:4] != b"LASF":
        sys.exit("segmented.laz is not whole: %d bytes downloaded, %d listed, starts %r" % (len(data), files["segmented.laz"], data[:4]))
    log("segmented.laz whole: %d bytes" % len(data))
else:
    sys.exit("unknown step " + step)
