#!/usr/bin/env bash
# One release CI scenario: scenario.sh <name>. Exits non-zero (and prints diagnostics) when the scenario fails.
# Environment: N (this build's version), DIST (this build's files: release-common + this platform's zip), PLAT,
# RELEASES_REPO, GH_TOKEN; PREV (the release before this build) for the scenarios that start from it.
#
#   self-update-holders  Windows. The previous release, running, updates itself to this build while an orphaned
#                        Python of its own (.tools) and a foreign program (cmd.exe, and a process holding a file open)
#                        work in its app folder (app-<prev>\backend). Must install: this build serves.
#   self-update / self-update-export   the same, with the segmented-cloud export running when the update arrives:
#                        the update waits for it; it finishes whole, not interrupted (the release gate).
#   legacy-orphan        Windows, Darryl's case. v0.3.7's full zip (the old app\ layout), started; its launcher dies
#                        and leaves its uv and Python serving from app\backend (plus an orphaned worker there). This
#                        build's one-liner, then a start: this build serves, alone, the workspace is kept.
#   legacy-foreign       the same, but the old app is closed and only foreign programs (cmd.exe, an open file) and an
#                        orphaned .tools Python hold app\backend.
#   running              The one-liner while the previous release is running: on 8765, and on 8766 with 8765 held by
#                        another program. Then a start: this build serves, one backend for the install, workspace kept.
#   single-instance      8765 held by another program; the app started twice 0.3 s apart, then again 10 s later.
#                        Exactly one backend serves the install; the later launches exit 0 and name its URL.
#   profile-paths        A profile/home with a space and non-ASCII characters (Windows: USERPROFILE; macOS/Linux:
#                        HOME): one-liner (default folder), version, doctor, self-check (not on macOS: verify runs it),
#                        serve, uninstall (workspace kept; program, shortcuts, PATH entry, link gone).
#   offline              After the install, started with every proxy variable pointing at a proxy that refuses all:
#                        the app serves, the update check went to the proxy and failed quietly (no error status).
#                        macOS also: the install's files (all but the launcher) carry the download quarantine
#                        first; start clears it (S15). Linux also: started with no xdg-open, notify-send or DISPLAY,
#                        browser and notifications on: serves, prints the URL (S16); a read-only install folder and a
#                        64 MB install folder: refused with a clear message, nothing changed (S13).
#   rollback             This build installed; a broken next version v9.9.9 (its backend exits on import) is served.
#                        The launcher installs it, it does not come up, it is rolled back: this build serves again,
#                        skip.txt and the error status name v9.9.9, it is not installed a second time.
#                        Also the bad downloads: truncated, a flipped byte, a proxy's HTML page, for the one-liner
#                        and for `shaft-analyser update`: each refused, the install untouched.
SCENARIO=$1
. "$(dirname "$0")/lib.sh"
say "scenario $SCENARIO on $RUNNER_OS: this build $N${PREV:+, previous release $PREV}"
export SHAFT_NOTIFY=0
UP=240   # seconds for a start to serve (first start of a version prepares Python: ~30 s here)

# ---- process helpers -------------------------------------------------------------------------------------------------
winpid() { cat "/proc/$1/winpid" 2> /dev/null || echo "$1"; }
# kill_tree <pid>: a process started here and everything it started (an app closed with its window)
kill_tree() {
  if $WIN; then taskkill //T //F //PID "$(winpid "$1")" > /dev/null 2>&1 || true; return 0; fi
  local kids k; kids=$(pgrep -P "$1" || true)
  kill -9 "$1" 2> /dev/null || true
  for k in $kids; do kill_tree "$k"; done
}
# kill_only <pid>: the process alone; what it started lives on (a launcher that crashed)
kill_only() { if $WIN; then taskkill //F //PID "$(winpid "$1")" > /dev/null 2>&1 || true; else kill -9 "$1" 2> /dev/null || true; fi; }
# wait_exit <pid> <seconds>: until it exits; sets RC to its exit status (124: still running)
wait_exit() {
  local i; RC=124
  for i in $(seq $(($2 * 5))); do alive "$1" || { wait "$1" && RC=0 || RC=$?; return 0; }; sleep 0.2; done
}
# Windows holders of a folder. tools: the install's own Python sleeping there (an orphaned worker); foreign: cmd.exe +
# ping there, and a PowerShell holding one of its files open (an editor, an antivirus scan)
hold_tools() {
  (cd "$2" && exec "$1/.tools/venv/Scripts/python.exe" -c "import time; time.sleep(1500)") &
  HOLDERS+=($!); SA_PIDS+=($!)
}
hold_foreign() {
  (cd "$1" && exec cmd //c "ping -n 1500 127.0.0.1 >nul") &
  HOLDERS+=($!); SA_PIDS+=($!)
  local f; f=$(wp "$1/pyproject.toml")
  powershell -NoProfile -Command "\$f = [IO.File]::Open('$f', 'Open', 'Read', 'Read'); Start-Sleep 1500" &
  HOLDERS+=($!); SA_PIDS+=($!)
}
holders_alive() {
  local p; sleep 2
  for p in "${HOLDERS[@]}"; do alive "$p" || fail "holder pid $p is not running: the scenario would prove nothing"; done
  ok "${#HOLDERS[@]} holders running in $1"
}
HOLDERS=()

# ---- the scenarios -------------------------------------------------------------------------------------------------
self_update() {   # self-update-holders / self-update-export (Windows)
  local H; H="$(up "$USERPROFILE")/ShaftAnalyser"
  install_prev "$H"; plant_shaft "$H"
  local gate="$T/allow-update"
  serve "$DIST" "$N" 8012 --gate "$(wp "$gate")"
  SHAFT_UPDATE_BASE=http://127.0.0.1:8012 SHAFT_UPDATE_CHECK_S=10 launch prev "$(exe_of "$H")" start --no-browser
  local port; port=$(wait_up "$H" $UP) || fail "$PREV did not come up"
  ok "$PREV serves on $port"
  local app; app=$(app_in_use "$H")
  if [ "$1" = export ]; then
    "$PY" -I "$(wp "$HERE/job.py")" "$port" "$(wp "$H/sample_input/synthetic_shaft.laz")" "$(wp "$T")" start || fail "the job could not be started"
  fi
  hold_tools "$H" "$app/backend"; hold_foreign "$app/backend"; holders_alive "$app/backend"
  touch "$gate"; say "update allowed: /latest -> $N"
  if [ "$1" = export ]; then
    "$PY" -I "$(wp "$HERE/job.py")" "$port" "" "$(wp "$T")" finish || fail "the exports running during the update did not finish whole"
    ok "the exports finished whole while $N was waiting to install"
  fi
  port=$(wait_version "$H" "$N" 480) || fail "$PREV did not update itself to $N with $(basename "$app")\\backend held"
  holders_alive "$app/backend"
  local st i; for i in $(seq 20); do st=$(field "$H/updates/status.json" state); [ "$st" = updated ] || [ "$st" = current ] && break; sleep 1; done
  [ "$st" = updated ] || [ "$st" = current ] || fail "status.json state is '$st', expected updated"
  [ "$(field "$H/updates/status.json" current)" = "$N" ] || fail "status.json current is not $N"
  [ "$(tr -d '[:space:]' < "$H/app.current")" = "app-$N" ] || fail "app.current is '$(cat "$H/app.current")', expected app-$N"
  "$(exe_of "$H")" version | grep -F "$N" || fail "the launcher was not replaced by $N's"
  exactly_one "$H"; shaft_kept "$H"
  ok "$PREV updated itself to $N while held (port $port, status $st)"
}

legacy() {   # legacy-orphan / legacy-foreign (Windows)
  local H; H="$(up "$USERPROFILE")/ShaftAnalyser" L=v0.3.7
  mkdir -p "$T/legacy"
  gh release download "$L" --repo "$RELEASES_REPO" --dir "$T/legacy" --pattern "ShaftAnalyser-$L-windows-x64.zip"
  unzip -q "$T/legacy/ShaftAnalyser-$L-windows-x64.zip" -d "$(dirname "$H")"
  HOMES+=("$H"); [ -f "$H/app/VERSION" ] && [ ! -e "$H/app.current" ] || fail "$L's zip is not the app\\ layout"
  SHAFT_AUTO_UPDATE=0 launch legacy "$(exe_of "$H")" start --no-browser
  local lpid=$LAUNCHED port; port=$(wait_up "$H" $UP) || fail "$L did not come up"
  ok "$L serves on $port from $H\\app"
  plant_shaft "$H"
  if [ "$1" = orphan ]; then
    kill_only "$lpid"; sleep 2
    [ -n "$(ours "$H")" ] || fail "the orphaned server is not answering (nothing left to test)"
    ok "launcher killed; its uv and Python still serve on $port from app\\backend"
    hold_tools "$H" "$H/app/backend"; holders_alive "$H/app/backend"
  else
    kill_tree "$lpid"; sleep 2
    [ -z "$(ours "$H")" ] || fail "$L still serves after it was closed"
    hold_tools "$H" "$H/app/backend"; hold_foreign "$H/app/backend"; holders_alive "$H/app/backend"
  fi
  serve_this
  one_liner "$H" "$(this_base)" "$LOGS/install-this.log" || fail "this build's one-liner failed over $L with app\\backend held"
  SHAFT_AUTO_UPDATE=0 launch new "$(exe_of "$H")" start --no-browser
  port=$(wait_version "$H" "$N" $UP) || fail "after the one-liner over $L the install does not serve $N (serves: $(ours "$H" | tr '\n' ';'))"
  exactly_one "$H"; shaft_kept "$H"
  [ "$(tr -d '[:space:]' < "$H/app.current")" = "app-$N" ] || fail "app.current is '$(cat "$H/app.current" 2> /dev/null)', expected app-$N"
  "$(exe_of "$H")" version | grep -F "$N" || fail "shaft-analyser.exe is not $N's"
  "$(exe_of "$H")" doctor || fail "doctor fails after the upgrade over $L"
  ok "$L ($1 holder) upgraded to $N by the one-liner; serves on $port"
}

running_case() {   # running_case <home>: 8765 held by another program (moved) or not
  local H=$1 moved=false port0 port old new
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765/api/health)" = 404 ] && moved=true
  install_prev "$H"; plant_shaft "$H"
  SHAFT_AUTO_UPDATE=0 launch "prev-$(basename "$(dirname "$H")")" "$(exe_of "$H")" start --no-browser; old=$LAUNCHED
  port0=$(wait_up "$H" $UP) || fail "$PREV did not come up"
  if $moved; then [ "$port0" != 8765 ] || fail "$PREV took 8765 although it is held"; fi
  ok "$PREV running from $H on $port0 (launcher pid $old)"
  local t0; t0=$(date +%s)
  one_liner "$H" "$(this_base)" "$LOGS/install-this-$(basename "$(dirname "$H")").log" \
    || fail "the one-liner failed while $PREV was running on $port0"
  SHAFT_AUTO_UPDATE=0 launch "new-$(basename "$(dirname "$H")")" "$(exe_of "$H")" start --no-browser; new=$LAUNCHED
  port=$(wait_version "$H" "$N" $UP) \
    || fail "after the one-liner (run while $PREV served on $port0) the install does not serve $N; it serves: $(ours "$H" | tr '\n' ';') (installer: $(grep -iE 'running|close|failed' "$LOGS/install-this-$(basename "$(dirname "$H")").log" | head -2 | tr '\n' ' '))"
  # an old app whose files were replaced under it reports the new VERSION from disk: settle, then judge processes
  sleep 15
  exactly_one "$H"; shaft_kept "$H"
  port=$(ours "$H" | head -1 | cut -d' ' -f1)
  local ts; ts=$(listener_start "$port")
  say "the backend on $port started at $ts; the one-liner started at $t0"
  [ -n "$ts" ] && [ "$ts" -ge "$t0" ] || fail "the backend serving the install on $port is $PREV's, started before the one-liner (its files were replaced under it, so it reports $N): the old app was never stopped"
  alive "$new" || probe version "$port" > /dev/null || fail "nothing serves after the new launch"
  ok "one-liner while $PREV ran on $port0: $PREV stopped, $N serves on $port"
}
running() {   # both cases, each reported (a subshell each: its failure prints its diagnostics and ends only it)
  local r1=0 r2=0
  serve_this
  dummy_listener 8765; local dummy=$DUMMY
  ( trap on_exit EXIT; SCENARIO="running (8765 held, app on a moved port)"; running_case "$T/moved/ShaftAnalyser" ) || r1=$?
  kill "$dummy" 2> /dev/null || true; sleep 1
  ( trap on_exit EXIT; SCENARIO="running (app on 8765)"; running_case "$T/default/ShaftAnalyser" ) || r2=$?
  [ "$r1" = 0 ] && [ "$r2" = 0 ] || fail "one-liner while the previous release runs: moved port $([ $r1 = 0 ] && echo passed || echo FAILED), 8765 $([ $r2 = 0 ] && echo passed || echo FAILED)"
}

single_instance() {   # both launch patterns are judged, each problem reported, then the scenario fails if any
  local H="$T/single/ShaftAnalyser" port a b c probs=()
  serve_this; install_this "$H"; plant_shaft "$H"
  dummy_listener 8765
  SHAFT_AUTO_UPDATE=0 launch first "$(exe_of "$H")" start --no-browser; a=$LAUNCHED
  sleep 0.3
  SHAFT_AUTO_UPDATE=0 launch second "$(exe_of "$H")" start --no-browser; b=$LAUNCHED
  port=$(wait_up "$H" $UP) || fail "the app did not come up"
  ok "serving on $port"
  wait_exit "$b" 90; local rb=$RC ra=124
  if [ "$rb" = 124 ]; then wait_exit "$a" 5; ra=$RC; fi
  if [ "$rb" = 124 ] && [ "$ra" = 124 ]; then
    probs+=("S6: two launches 0.3 s apart both kept running ($(ours "$H" | tr '\n' ';'))")
  else
    local rsecond=$rb; [ "$rb" = 124 ] && rsecond=$ra
    [ "$rsecond" = 0 ] || probs+=("S6: of two launches 0.3 s apart the second exited $rsecond, not 0 ('already running'): $(grep -iE 'error|already' "$LOGS/second.log" "$LOGS/first.log" | head -2 | tr '\n' ' ')")
  fi
  port=$(wait_up "$H" 30) || fail "nothing serves the install after the first two launches"
  sleep 10
  SHAFT_AUTO_UPDATE=0 launch third "$(exe_of "$H")" start --no-browser; c=$LAUNCHED
  wait_exit "$c" 90
  if [ "$RC" = 124 ]; then probs+=("S5: a launch 10 s later kept running: a second backend ($(ours "$H" | tr '\n' ';'))")
  elif [ "$RC" != 0 ]; then probs+=("S5: a launch 10 s later exited $RC, not 0")
  elif ! grep -qF "127.0.0.1:$port" "$LOGS/third.log"; then probs+=("S5: a launch 10 s later did not name the running app's URL http://127.0.0.1:$port")
  fi
  local n; n=$(ours "$H" | grep -c . || true)
  [ "$n" = 1 ] || probs+=("$n backends serve the install's workspace at the end: $(ours "$H" | tr '\n' ';')")
  if [ ${#probs[@]} -gt 0 ]; then
    local p; for p in "${probs[@]}"; do printf '::error::single-instance: %s\n' "$p"; done
    fail "${#probs[@]} problem(s): ${probs[*]}"
  fi
  ok "one backend on $port; the later launches said so and exited 0"
}

profile_paths() {
  local P
  if $WIN; then
    P="$(up 'C:\Users')/J$(printf '\xc3\xb6')rg M$(printf '\xc3\xbc')ller"
    mkdir -p "$P/Desktop"; export USERPROFILE; USERPROFILE="$(wp "$P")"
  else
    P="$T/J$(printf '\xc3\xb6')rg M$(printf '\xc3\xbc')ller"; mkdir -p "$P"; export HOME="$P"
  fi
  local H="$P/ShaftAnalyser"
  say "profile: $(wp "$P")"
  serve_this
  ONE_LINER_DEFAULT_HOME=1 one_liner "$H" "$(this_base)" "$LOGS/install-this.log" || fail "the one-liner failed with the profile $(wp "$P")"
  HOMES+=("$H")
  [ -x "$(exe_of "$H")" ] || fail "the default install folder is not $(wp "$H")"
  plant_shaft "$H"
  "$(exe_of "$H")" version | grep -F "$N" || fail "version"
  "$(exe_of "$H")" doctor || fail "doctor fails in $(wp "$H")"
  if [ "$RUNNER_OS" != macOS ]; then "$(exe_of "$H")" check || fail "the self-check fails in $(wp "$H")"; fi
  SHAFT_AUTO_UPDATE=0 launch app "$(exe_of "$H")" start --no-browser; local a=$LAUNCHED port
  port=$(wait_version "$H" "$N" $UP) || fail "the app does not serve from $(wp "$H")"
  probe page "$port" || fail "the app's page is not served"
  kill_tree "$a"; sleep 3
  "$(exe_of "$H")" uninstall | tee "$LOGS/uninstall.log" || fail "uninstall failed"
  local i; for i in $(seq 30); do [ -e "$(exe_of "$H")" ] || break; sleep 1; done
  if [ -e "$(exe_of "$H")" ] && $WIN; then   # is it the path? the same self-delete from an ASCII folder, for the record
    local C=/c/sa-control/ShaftAnalyser; mkdir -p "$C"; cp "$(exe_of "$H")" "$C/"
    "$C/shaft-analyser.exe" uninstall > /dev/null 2>&1 || true
    for i in $(seq 15); do [ -e "$C/shaft-analyser.exe" ] || break; sleep 1; done
    say "control: uninstall from C:\\sa-control\\ShaftAnalyser $([ -e "$C/shaft-analyser.exe" ] && echo 'ALSO left the program' || echo 'removed the program')"
  fi
  [ ! -e "$(exe_of "$H")" ] || fail "uninstall left the program $(exe_of "$H")"
  for d in .tools updates sample_input "app-$N" app app.current; do [ ! -e "$H/$d" ] || fail "uninstall left $d"; done
  shaft_kept "$H"
  if $WIN; then
    SC_DIR="$(wp "$H")" powershell -NoProfile -Command "if (([Environment]::GetEnvironmentVariable('Path','User') -split ';') -contains \$env:SC_DIR) { exit 1 }" \
      || fail "uninstall left $(wp "$H") in the user PATH"
    [ ! -e "$(up "$(powershell -NoProfile -Command "[Environment]::GetFolderPath('Desktop')" | tr -d '\r')")/Shaft Analyser.lnk" ] || fail "uninstall left the desktop shortcut"
  else
    [ ! -e "$HOME/.local/bin/shaft-analyser" ] && [ ! -L "$HOME/.local/bin/shaft-analyser" ] || fail "uninstall left ~/.local/bin/shaft-analyser"
  fi
  ok "install, doctor, check, serve and uninstall with the profile $(wp "$P")"
}

offline() {
  local H="$T/offline/ShaftAnalyser" port
  serve_this; install_this "$H"
  [ "$RUNNER_OS" = macOS ] && plant_quarantine "$H"   # G7 (S15): started from a quarantined folder, offline too
  "$PY" -I -c "
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 18080)); s.listen(50)
while True:
    c, _ = s.accept(); open(sys.argv[1], 'a').write(time.strftime('%H:%M:%S') + ' refused\n'); c.close()
" "$(wp "$LOGS/proxy.log")" &
  SA_PIDS+=($!); sleep 1
  HTTPS_PROXY=http://127.0.0.1:18080 HTTP_PROXY=http://127.0.0.1:18080 ALL_PROXY=http://127.0.0.1:18080 SHAFT_UPDATE_CHECK_S=5 \
    launch offline "$(exe_of "$H")" start --no-browser
  local a=$LAUNCHED
  port=$(wait_version "$H" "$N" $UP) || fail "the app does not start offline"
  probe page "$port" || fail "the app's page is not served offline"
  sleep 30
  alive "$a" || fail "the launcher exited while offline"
  [ -s "$LOGS/proxy.log" ] || fail "the update check never went to the proxy (the scenario would prove nothing)"
  local st; st=$(field "$H/updates/status.json" state)
  [ "$st" != error ] || fail "offline, status.json says error: $(field "$H/updates/status.json" message)"
  probe version "$port" > /dev/null || fail "the app stopped answering"
  ok "offline: serves $N on $port; $(wc -l < "$LOGS/proxy.log" | tr -d ' ') update checks refused by the proxy, status '${st:-none}'"
  [ "$RUNNER_OS" = macOS ] && quarantine_cleared "$H"
  kill_tree "$a"; sleep 2
  [ "$RUNNER_OS" = Linux ] || return 0
  headless "$H"   # G7 (S16)
  # S13: a read-only install folder: the one-liner refuses, the install is untouched
  local before after rc=0
  before=$(cd "$H" && find . -path ./workspace -prune -o -print | sort | md5sum)
  chmod -R a-w "$H"
  one_liner "$H" "$(this_base)" "$LOGS/install-readonly.log" || rc=$?
  chmod -R u+w "$H"
  after=$(cd "$H" && find . -path ./workspace -prune -o -print | sort | md5sum)
  [ "$rc" != 0 ] || fail "the one-liner into a read-only folder reported success"
  [ "$before" = "$after" ] || fail "the one-liner into a read-only folder changed it"
  "$(exe_of "$H")" version | grep -F "$N" || fail "the install does not run after the read-only attempt"
  ok "read-only folder: refused (exit $rc: $(grep -iE 'denied|read-only|writ' "$LOGS/install-readonly.log" | head -1)), untouched"
  # S13: a 64 MB install folder: refused with a clear message
  local S="$T/small"; mkdir -p "$S"; sudo mount -t tmpfs -o size=64m tmpfs "$S"; sudo chown "$(id -u):$(id -g)" "$S"
  rc=0; one_liner "$S/ShaftAnalyser" "$(this_base)" "$LOGS/install-small.log" || rc=$?
  [ "$rc" != 0 ] || fail "the one-liner into a 64 MB folder reported success"
  grep -qiE 'space|disk|free|full' "$LOGS/install-small.log" || fail "the one-liner into a 64 MB folder failed without saying the disk is full"
  ok "64 MB folder: refused (exit $rc: $(grep -iE 'space|disk|free|full' "$LOGS/install-small.log" | head -1))"
  sudo umount "$S" || true
}

rollback() {
  local H="$T/rb/ShaftAnalyser" B="$T/broken" port
  serve_this; install_this "$H"; plant_shaft "$H"
  # the broken next version: this build's app zip, app/VERSION v9.9.9, its backend exits on import
  mkdir -p "$B"
  "$PY" -I -c "
import hashlib, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst + '/shaft-analyser-app.zip', 'w', zipfile.ZIP_DEFLATED) as zo:
    for i in zi.infolist():
        d = zi.read(i.filename)
        if i.filename == 'app/VERSION': d = b'v9.9.9\n'
        if i.filename == 'app/backend/src/shaft/__init__.py': d = b'raise SystemExit(\"CI: this release is broken on purpose\")\n'
        zo.writestr(i, d)
h = hashlib.sha256(open(dst + '/shaft-analyser-app.zip', 'rb').read()).hexdigest()
open(dst + '/checksums.txt', 'w').write(h + '  shaft-analyser-app.zip\n')
" "$(wp "$DIST/shaft-analyser-app.zip")" "$(wp "$B")"
  serve "$B" v9.9.9 8012 --gate "$(wp "$T/allow-broken")"
  SHAFT_UPDATE_BASE=http://127.0.0.1:8012 SHAFT_UPDATE_CHECK_S=10 launch rb "$(exe_of "$H")" start --no-browser
  local a=$LAUNCHED
  port=$(wait_version "$H" "$N" $UP) || fail "$N did not come up"
  ok "$N serves on $port; v9.9.9 (broken) is the newest release"
  touch "$T/allow-broken"; say "v9.9.9 offered: /latest -> v9.9.9"
  local msg   # the error status lasts until the next update check (~10 s): watched every 0.1 s
  msg=$(probe watch "$(wp "$H/updates/status.json")" error v9.9.9 450) || { alive "$a" || fail "the launcher exited during the bad update"; fail "no error status for v9.9.9 within 7.5 min"; }
  grep -q "Installed v9.9.9" "$LOGS/rb.log" || fail "the launcher never installed v9.9.9 (the scenario would prove nothing)"
  ok "error status: $msg"
  port=$(wait_version "$H" "$N" $UP) || fail "after the roll back $N does not serve again (serves: $(ours "$H" | tr '\n' ';'))"
  grep -qx v9.9.9 "$H/updates/skip.txt" || fail "skip.txt does not name v9.9.9"
  [ "$(installed_version "$H")" = "$N" ] || fail "the app folder in use is $(installed_version "$H"), not $N"
  sleep 40   # two more update checks: v9.9.9 is not installed again
  [ "$(grep -c "Installed v9.9.9" "$LOGS/rb.log")" = 1 ] || fail "v9.9.9 was installed again after its roll back"
  probe version "$port" | grep -qx "$N" || fail "$N stopped serving after the roll back"
  exactly_one "$H"; shaft_kept "$H"
  ok "v9.9.9 rolled back; $N serves on $port; skipped from now on"
  kill_tree "$a"; sleep 2
  bad_downloads "$H"
}

snapshot() { (cd "$1" && find . -path ./workspace -prune -o -path ./.tools -prune -o -type f -print | sort | while read -r f; do cksum "$f"; done) | cksum; }
bad_downloads() {
  local H=$1 mode before rc port=8020 out
  before=$(snapshot "$H")
  for mode in truncate flip html; do
    port=$((port + 1))
    serve "$DIST" "$N" "$port" --mode "$mode"
    rc=0; ONE_LINER_SCRIPT_BASE="$(this_base)" one_liner "$H" "http://127.0.0.1:$port/download/$N" "$LOGS/install-$mode.log" || rc=$?
    [ "$rc" != 0 ] || fail "the one-liner reported success with a $mode download"
    [ "$(snapshot "$H")" = "$before" ] || fail "the one-liner with a $mode download changed the install"
    ok "one-liner, $mode download: refused (exit $rc: $(grep -iE 'checksum|cannot|no package|fail' "$LOGS/install-$mode.log" | head -1)), install untouched"
    port=$((port + 1))
    serve "$DIST" v9.9.9 "$port" --mode "$mode"
    rc=0; out=$(SHAFT_UPDATE_BASE="http://127.0.0.1:$port" "$(exe_of "$H")" update 2>&1) || rc=$?
    echo "$out" | sed 's/^/    update| /'
    [ "$rc" != 0 ] || fail "shaft-analyser update reported success with a $mode download"
    [ ! -e "$H/updates/staged/READY" ] || fail "a $mode download was staged for installing"
    [ "$(snapshot "$H")" = "$before" ] || fail "shaft-analyser update with a $mode download changed the install"
    ok "update, $mode download: refused (exit $rc), install untouched"
  done
  "$(exe_of "$H")" version | grep -F "$N" || fail "the install does not run after the bad downloads"
}

plant_quarantine() {   # every file and folder of the install but the launcher, as a browser-downloaded zip gives them
  local H=$1 n
  find "$H" -path "$H/workspace" -prune -o \( -type f -o -type d \) ! -path "$(exe_of "$H")" -print0 \
    | xargs -0 xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;CI" 2> /dev/null || true   # (planting; counted below)
  n=$(xattr -r -l "$H" 2> /dev/null | grep -c com.apple.quarantine || true)
  [ "$n" -gt 100 ] || fail "quarantine was not planted ($n files)"
  ok "quarantine planted on $n files"
}
quarantine_cleared() {
  local n; n=$(xattr -r -l "$1" 2> /dev/null | grep -c com.apple.quarantine || true)
  [ "$n" = 0 ] || fail "$n files still carry the quarantine after start"
  ok "start cleared the quarantine"
}

headless() {   # headless <home>: an installed copy started with browser and notifications on, no desktop
  local H=$1 port bin="$T/bin"
  mkdir -p "$bin"
  for d in /usr/local/bin /usr/bin /bin; do
    for f in "$d"/*; do
      case "$(basename "$f")" in xdg-open|notify-send|x-www-browser|www-browser|sensible-browser|gio|firefox|google-chrome*|chromium*|microsoft-edge*) continue;; esac
      [ -e "$bin/$(basename "$f")" ] || ln -s "$f" "$bin/$(basename "$f")"
    done
  done
  if PATH="$bin" command -v xdg-open > /dev/null; then fail "xdg-open still on the PATH"; fi
  launch hl env -u DISPLAY -u WAYLAND_DISPLAY -u BROWSER PATH="$bin" SHAFT_NOTIFY=1 SHAFT_AUTO_UPDATE=0 "$(exe_of "$H")" start
  local a=$LAUNCHED
  port=$(wait_version "$H" "$N" $UP) || fail "the app does not start without a desktop"
  sleep 5
  alive "$a" || fail "the launcher exited without a desktop"
  grep -F "http://127.0.0.1:$port" "$LOGS/hl.log" || fail "the URL was not printed"
  ok "headless: serves $N on $port, URL printed, no browser or notifier needed"
  kill_tree "$a"
}

case $SCENARIO in
  self-update-holders) self_update holders ;;
  self-update-export|self-update) self_update export ;;
  legacy-orphan) legacy orphan ;;
  legacy-foreign) legacy foreign ;;
  running) running ;;
  single-instance) single_instance ;;
  profile-paths) profile_paths ;;
  offline) offline ;;
  rollback) rollback ;;
  *) fail "unknown scenario $SCENARIO" ;;
esac
