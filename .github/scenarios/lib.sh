# Shared by the release CI scenarios (bash on Linux, macOS and Windows' Git Bash). Sourced by scenario.sh.
# Every assertion goes through `fail`, which exits non-zero; on any non-zero exit the diagnostics are printed:
# status.json, app.current, the launchers' consoles, the processes, the listening ports and, on Windows, handle64.
# Needs: N (this build's version), DIST (this build's files), PLAT; PREV (previous release) where a scenario uses it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || command -v python)"
WIN=false; [ "${RUNNER_OS:-}" = Windows ] && WIN=true
T="${RUNNER_TEMP:-/tmp}/sc"; LOGS="$T/logs"; mkdir -p "$LOGS"
HOMES=()          # install folders the diagnostics look at
SA_PIDS=()        # background processes started here (launchers, servers, holders)

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '::error::%s: %s\n' "${SCENARIO:-scenario}" "$*"; say "FAIL: $*"; exit 1; }
ok() { say "ok: $*"; }
# a path as the programs on this OS read it (C:\... on Windows)
wp() { if $WIN; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
up() { if $WIN; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
probe() { "$PY" -I "$(wp "$HERE/probe.py")" "$@"; }
exe_of() { if $WIN; then echo "$1/shaft-analyser.exe"; else echo "$1/shaft-analyser"; fi; }

# ---- the release servers -------------------------------------------------------------------------------------------
# serve <dir> <tag> <port> [extra args for release_server.py]: github.com's release links for <dir> as release <tag>
serve() {
  local dir=$1 tag=$2 port=$3; shift 3
  "$PY" -I "$(wp "$HERE/release_server.py")" "$(wp "$dir")" "$tag" "$port" --log "$(wp "$LOGS/server-$port.log")" "$@" \
    > "$LOGS/server-$port.out" 2>&1 &
  SA_PIDS+=($!)
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && return 0; sleep 0.2; done
  fail "release server on $port did not come up"
}
this_base() { echo "http://127.0.0.1:8011/download/$N"; }       # this build, as the installers download it
serve_this() { serve "$DIST" "$N" 8011; }

# ---- installs -------------------------------------------------------------------------------------------------------
# one_liner <home> <release url> <log>: the documented one-line install into <home>, not starting the app.
# Exit status: the installer's (install.ps1 under `irm | iex` exits 0 even when it fails: its message counts).
one_liner() {
  local home=$1 base=$2 log=$3 rc=0 sh_home
  sh_home=$(wp "$home"); [ "${ONE_LINER_DEFAULT_HOME:-}" = 1 ] && sh_home=""   # the installer's own default folder
  if $WIN; then
    SHAFT_HOME="$sh_home" SHAFT_RELEASE_URL="$base" SHAFT_NO_START=1 \
      powershell -NoProfile -ExecutionPolicy Bypass -Command "irm $base/install.ps1 | iex" > "$log" 2>&1 || rc=$?
    grep -q "shaft-analyser install failed" "$log" && rc=${rc/#0/1}
  else
    { curl -fsSL "$base/install.sh" | SHAFT_HOME="$sh_home" SHAFT_RELEASE_URL="$base" SHAFT_NO_START=1 sh; } > "$log" 2>&1 || rc=$?
  fi
  sed 's/^/    install| /' "$log"
  return $rc
}
install_this() { one_liner "$1" "$(this_base)" "$LOGS/install-this-$(basename "$(dirname "$1")").log" || fail "this build's one-line install into $1 failed"; HOMES+=("$1"); }
# the previous release, installed by its own one-liner from github.com (the layout a client has)
install_prev() {
  local tag=${2:-$PREV}
  one_liner "$1" "https://github.com/$RELEASES_REPO/releases/download/$tag" "$LOGS/install-$tag-$(basename "$(dirname "$1")").log" \
    || fail "installing $tag into $1 failed"
  HOMES+=("$1")
}

# ---- the app -------------------------------------------------------------------------------------------------------
# launch <name> <exe> [args]: the launcher in the background, its console in $LOGS/<name>.log, its pid in $LAUNCHED
launch() {
  local name=$1; shift
  "$@" > "$LOGS/$name.log" 2>&1 &
  LAUNCHED=$!; SA_PIDS+=($LAUNCHED)
  say "started $name: $* (pid $LAUNCHED)"
}
alive() { kill -0 "$1" 2> /dev/null; }
# ours <home>: "<port> <version>" for each port serving this install's workspace
ours() { probe ours "$(wp "$1/workspace")"; }
# wait_up <home> <seconds>: until this install serves; prints the port
wait_up() {
  local i out
  for i in $(seq "$2"); do
    out=$(ours "$1"); [ -n "$out" ] && { echo "$out" | head -1 | cut -d' ' -f1; return 0; }
    sleep 1
  done
  return 1
}
# wait_version <home> <version> <seconds>: until this install serves <version>; prints the port
wait_version() {
  local i out
  for i in $(seq "$3"); do
    out=$(ours "$1" | awk -v v="$2" '$2 == v {print $1; exit}'); [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 1
  done
  return 1
}
# exactly_one <home>: one backend serves this install (a second one on another port is a second app on the same
# workspace: it marks the first one's jobs Interrupted)
exactly_one() {
  local out n; out=$(ours "$1"); n=$(printf '%s' "$out" | grep -c . || true)
  say "backends serving $1/workspace: $n${out:+ ($(echo "$out" | tr '\n' ';'))}"
  [ "$n" = 1 ] || fail "$n backends serve the workspace of $1 (expected exactly one): $(echo "$out" | tr '\n' ';')"
}
app_in_use() {   # the app folder in use: app.current's, else app
  local c; c=$(tr -d '[:space:]' < "$1/app.current" 2> /dev/null || true)
  if [ -n "$c" ] && [ -f "$1/$c/VERSION" ]; then echo "$1/$c"; else echo "$1/app"; fi
}
installed_version() { tr -d '[:space:]' < "$(app_in_use "$1")/VERSION"; }
# a planted shaft in the workspace: kept by every install, update and uninstall
plant_shaft() { mkdir -p "$1/workspace/shafts/ci-shaft"; echo '{"id":"ci-shaft","name":"CI shaft"}' > "$1/workspace/shafts/ci-shaft/shaft.json"; }
shaft_kept() { [ -f "$1/workspace/shafts/ci-shaft/shaft.json" ] || fail "the workspace of $1 lost its shafts (workspace/shafts/ci-shaft)"; ok "workspace of $1 kept"; }
dummy_listener() {   # a foreign program on <port>
  "$PY" -I "$(wp "$HERE/probe.py")" listen "$1" > "$LOGS/listener-$1.log" 2>&1 &
  DUMMY=$!; SA_PIDS+=($!)
  for _ in $(seq 50); do [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/api/health")" = 404 ] && { say "foreign listener on $1 (pid $DUMMY)"; return 0; }; sleep 0.2; done
  fail "the foreign listener on $1 did not come up"
}

# ---- diagnostics on failure -----------------------------------------------------------------------------------------
processes() {
  if $WIN; then
    powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.Name -match '^(shaft-analyser.*|python.*|uv.*|cmd|ping|powershell|pwsh)\.exe$' } |
      ForEach-Object { '{0,6} {1,6} {2,-22} {3}' -f \$_.ProcessId, \$_.ParentProcessId, \$_.Name, \$_.CommandLine }" 2>&1 || true
  else
    ps -eo pid,ppid,etime,command | grep -E 'shaft|uv |python|PID' | grep -v grep || true
  fi
}
listening() {
  if $WIN; then netstat -ano | grep LISTENING | grep -E ':(87[6-8][0-9]|80[0-9][0-9]|9999) ' || true
  elif [ "$RUNNER_OS" = macOS ]; then lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(87[6-8][0-9]|80[0-9][0-9])' || true
  else ss -ltnp 2> /dev/null | grep -E ':(87[6-8][0-9]|80[0-9][0-9])' || true; fi
}
handles() {
  $WIN || return 0
  local h="$T/handle64.exe"
  [ -f "$h" ] || curl -fsSL --retry 3 -o "$h" https://live.sysinternals.com/handle64.exe || { echo "(handle64 not available)"; return 0; }
  for home in ${HOMES[@]+"${HOMES[@]}"}; do echo "--- handle64 $home"; "$h" -accepteula -nobanner "$(wp "$home")" 2>&1 | head -60 || true; done
}
diagnostics() {
  echo "::group::diagnostics (${SCENARIO:-scenario})"
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    echo "===== $home"
    ls -la "$home" 2> /dev/null || echo "(missing)"
    echo "--- app.current: $(cat "$home/app.current" 2> /dev/null || echo '(none)')  previous.txt: $(cat "$home/updates/previous.txt" 2> /dev/null || echo '(none)')"
    echo "--- updates/status.json"; cat "$home/updates/status.json" 2> /dev/null || echo "(none)"; echo
    echo "--- updates/skip.txt"; cat "$home/updates/skip.txt" 2> /dev/null || echo "(none)"
    for d in "$home"/app "$home"/app-*; do [ -f "$d/VERSION" ] && echo "--- $(basename "$d")/VERSION = $(cat "$d/VERSION")"; done
  done
  for f in "$LOGS"/*; do [ -f "$f" ] || continue; echo "===== $(basename "$f") (last 80 lines)"; tail -n 80 "$f"; done
  echo "===== Shaft Analysers answering on 8765..8784"; probe all || true
  echo "===== listening ports"; listening
  echo "===== processes"; processes
  echo "===== handles"; handles
  echo "::endgroup::"
}
on_exit() {
  local rc=$?
  if [ "$rc" != 0 ]; then diagnostics; say "${SCENARIO:-scenario}: FAILED (exit $rc)"; else say "${SCENARIO:-scenario}: PASSED"; fi
  exit "$rc"
}
trap on_exit EXIT
