#!/bin/zsh
# Issue #246：对真实 Release App + SwiftUI 窗口采集 phys_footprint。
# 使用隔离 HOME / CFFIXED_USER_HOME，不碰用户正在使用的 Application Support。
# 不打印、不复制、不提交真实 tag / token / 原始 JSON。
set -euo pipefail

root="$(cd "${0:A:h}/../.." && pwd)"
cd "$root"

sha="$(git rev-parse HEAD)"
app="$root/.build/COCHelper.app"
bin="$app/Contents/MacOS/COCHelper"
results_dir="$root/Tools/perf/results/2026-08-24"
summary="$results_dir/issue-246-release-app-memory.json"
report="$results_dir/issue-246-release-app-memory.md"
user_history="$HOME/Library/Application Support/COCHelper/snapshot-history-v1.json"
user_prefs="$HOME/Library/Preferences/com.local.coc-helper.plist"
walls_before="$root/Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls_before.json"
walls_after="$root/Tests/COCHelperCoreTests/Fixtures/perf_account_snapshot_large_walls_after.json"

if [[ ! -x "$bin" ]]; then
  echo "missing Release app: $bin" >&2
  exit 1
fi
if [[ ! -f "$user_history" ]]; then
  echo "missing local 24-entry history (not committed): $user_history" >&2
  exit 1
fi
if [[ ! -f "$walls_before" || ! -f "$walls_after" ]]; then
  echo "missing large-walls fixtures" >&2
  exit 1
fi

mkdir -p "$results_dir"
sandbox="$(mktemp -d /tmp/cochelper-246-release-mem.XXXXXX)"
app_pid=""
trap 'if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" 2>/dev/null; then kill "$app_pid" 2>/dev/null || true; fi; rm -rf "$sandbox"' EXIT

entry_count="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("entries",[])))' "$user_history")"
history_bytes="$(wc -c < "$user_history" | tr -d ' ')"

log() { print -- "$*"; }

prepare_home() {
  local home="$1"
  rm -rf "$home"
  mkdir -p "$home/Library/Application Support/COCHelper"
  mkdir -p "$home/Library/Preferences"
  mkdir -p "$home/tmp"
}

seed_history_home() {
  local home="$1"
  prepare_home "$home"
  cp "$user_history" "$home/Library/Application Support/COCHelper/snapshot-history-v1.json"
  if [[ -f "$user_prefs" ]]; then
    cp "$user_prefs" "$home/Library/Preferences/com.local.coc-helper.plist"
  fi
}

launch_app() {
  local home="$1"
  local logf="$2"
  HOME="$home" CFFIXED_USER_HOME="$home" TMPDIR="$home/tmp" \
    "$bin" >"$logf" 2>&1 &
  app_pid=$!
  print -- "$app_pid"
}

wait_for_window() {
  local pid="$1"
  local i
  for i in {1..12}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "app pid $pid exited before window" >&2
      return 1
    fi
    if /usr/bin/osascript -e 'on run argv' \
      -e 'set targetPid to (item 1 of argv) as integer' \
      -e 'tell application "System Events"' \
      -e 'set procs to (every process whose unix id is targetPid)' \
      -e 'if (count of procs) is 0 then error "no process"' \
      -e 'tell item 1 of procs' \
      -e 'if (count of windows) is 0 then error "no windows"' \
      -e 'end tell' \
      -e 'end tell' \
      -e 'end run' \
      -- "$pid" >/dev/null 2>&1
    then
      return 0
    fi
    sleep 1
  done
  echo "timed out waiting for SwiftUI window pid=$pid; process still alive" >&2
  kill -0 "$pid" 2>/dev/null
}

stop_app() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    local i
    for i in {1..20}; do
      kill -0 "$pid" 2>/dev/null || { app_pid=""; return 0; }
      sleep 0.25
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  app_pid=""
}

sample_pid() {
  local pid="$1"
  local label="$2"
  local jsonf="$sandbox/${label}.footprint.json"
  local rawf="$sandbox/${label}.footprint.txt"
  /usr/bin/footprint -j "$jsonf" "$pid" >"$rawf" 2>&1 || true
  python3 - "$jsonf" "$rawf" "$pid" "$label" <<'PY'
import json, os, re, subprocess, sys
jsonf, rawf, pid, label = sys.argv[1:5]
phys = None
rss_kb = None
try:
    rss_kb = int(subprocess.check_output(["ps", "-o", "rss=", "-p", pid], text=True).strip() or "0")
except Exception:
    rss_kb = None

def walk(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            lk = str(k).lower().replace("-", "_")
            if lk in ("phys_footprint", "physfootprint", "footprint") and isinstance(v, (int, float)):
                yield lk, int(v)
            yield from walk(v)
    elif isinstance(obj, list):
        for item in obj:
            yield from walk(item)

if os.path.exists(jsonf) and os.path.getsize(jsonf) > 0:
    found = dict(walk(json.load(open(jsonf))))
    phys = found.get("phys_footprint") or found.get("physfootprint") or found.get("footprint")

text = open(rawf, errors="replace").read() if os.path.exists(rawf) else ""
if phys is None:
    m = re.search(r"phys_footprint[:\s]+([0-9]+)", text)
    if m:
        phys = int(m.group(1))
    else:
        m = re.search(r"Footprint:\s+([0-9]+(?:\.[0-9]+)?)\s*([KMG]B)?", text, re.I)
        if m:
            n = float(m.group(1))
            unit = (m.group(2) or "B").upper()
            mul = {"B": 1, "KB": 1000, "MB": 1000**2, "GB": 1000**3}.get(unit, 1)
            phys = int(n * mul)
print(json.dumps({
    "label": label,
    "pid": int(pid),
    "phys_footprint_bytes": phys,
    "rss_bytes": None if rss_kb is None else rss_kb * 1024,
}, ensure_ascii=False))
PY
}

click_named() {
  local pid="$1"
  local name="$2"
  osascript - "$pid" "$name" <<'APPLESCRIPT'
on run argv
  set targetPid to (item 1 of argv) as integer
  set targetName to item 2 of argv
  tell application "System Events"
    set procs to (every process whose unix id is targetPid)
    if (count of procs) is 0 then error "process not found"
    set proc to item 1 of procs
    set frontmost of proc to true
    delay 0.3
    if my walk(proc, targetName) then
      return "clicked"
    else
      error "UI name not found: " & targetName
    end if
  end tell
end run

on walk(elem, targetName)
  try
    if (name of elem is targetName) or (description of elem is targetName) then
      click elem
      return true
    end if
  end try
  try
    repeat with child in UI elements of elem
      if my walk(child, targetName) then return true
    end repeat
  end try
  return false
end walk
APPLESCRIPT
}

dump_ui() {
  local pid="$1"
  local out="$2"
  osascript - "$pid" >"$out" 2>&1 <<'APPLESCRIPT'
on run argv
  set targetPid to (item 1 of argv) as integer
  tell application "System Events"
    set procs to (every process whose unix id is targetPid)
    if (count of procs) is 0 then return "no process"
    return my namesOf(item 1 of procs, 0)
  end tell
end run

on namesOf(elem, depth)
  set acc to ""
  set pad to ""
  repeat depth times
    set pad to pad & "  "
  end repeat
  try
    set acc to acc & pad & (name of elem as text) & linefeed
  end try
  try
    repeat with child in UI elements of elem
      set acc to acc & my namesOf(child, depth + 1)
    end repeat
  end try
  return acc
end namesOf
APPLESCRIPT
}

import_fixture() {
  local pid="$1"
  local fixture="$2"
  pbcopy < "$fixture"
  sleep 0.4
  click_named "$pid" "账号数据" || return 1
  sleep 0.6
  click_named "$pid" "从剪贴板粘贴" || return 1
  sleep 0.6
  click_named "$pid" "解析文本" || return 1
  sleep 1.5
  click_named "$pid" "应用快照" || click_named "$pid" "创建「#LARGEWALL01」" || return 1
  sleep 2
  return 0
}

merge_json() {
  python3 - "$summary" "$1" "$2" <<'PY'
import json, sys
path, key, raw = sys.argv[1:4]
try:
    data = json.load(open(path))
except Exception:
    data = {}
data[key] = json.loads(raw)
json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
print("wrote", key)
PY
}

log "sha=$sha"
log "sandbox=$sandbox"
log "history_entries=$entry_count bytes=$history_bytes"

meta="$(python3 - <<PY
import json, platform, subprocess
print(json.dumps({
  "commit": "$sha",
  "app": ".build/COCHelper.app",
  "bundle_id": "com.local.coc-helper",
  "macos": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
  "arch": platform.machine(),
  "swift": subprocess.check_output(["swift", "--version"], text=True).splitlines()[0],
  "history_entries": int("$entry_count"),
  "history_bytes": int("$history_bytes"),
  "idle_seconds": 5,
  "isolated_home": True,
  "notes": "Release App binary with SwiftUI window; HOME/CFFIXED_USER_HOME isolated; no raw account JSON in this artifact",
}, ensure_ascii=False))
PY
)"
merge_json "meta" "$meta"

history_home="$sandbox/history-home"
for pass in 1 2; do
  seed_history_home "$history_home"
  log "launch 24-entry load pass=$pass"
  pid="$(launch_app "$history_home" "$sandbox/history-pass${pass}.log")"
  wait_for_window "$pid"
  sleep 5
  sample="$(sample_pid "$pid" "history-load-${pass}")"
  log "$sample"
  merge_json "history_load_${pass}" "$sample"
  stop_app "$pid"
  sleep 1
done

walls_home="$sandbox/walls-home"
prepare_home "$walls_home"
log "seed 1005-wall history via AppModel import path (same confirm path as Account Data UI)"
HOME="$walls_home" CFFIXED_USER_HOME="$walls_home" TMPDIR="$walls_home/tmp" \
  swift run -c release history-memory-seed "$walls_before" "$walls_after"
merge_json "walls_seed" '{"path":"AppModel.parseAccountText+applyPendingAccountSnapshot","imports":["before","after","after-duplicate"]}'

for pass in 1 2; do
  log "launch 1005-wall Release App load pass=$pass"
  pid="$(launch_app "$walls_home" "$sandbox/walls-pass${pass}.log")"
  wait_for_window "$pid" || true
  sleep 5
  sample="$(sample_pid "$pid" "walls-load-${pass}")"
  log "$sample"
  merge_json "walls_load_${pass}" "$sample"
  stop_app "$pid"
  sleep 1
done
merge_json "walls_ui_ok" '{"mode":"AppModel-seed then Release-App SwiftUI load","clicks":false}'

python3 - "$summary" "$report" <<'PY'
import json, sys
from pathlib import Path
summary_path, report_path = sys.argv[1], sys.argv[2]
d = json.load(open(summary_path))
meta = d.get("meta", {})

def mb(sample):
    if not sample or sample.get("phys_footprint_bytes") is None:
        return "unknown"
    return f"{sample['phys_footprint_bytes'] / (1024**2):.1f} MB"

def rss(sample):
    if not sample or sample.get("rss_bytes") is None:
        return "unknown"
    return f"{sample['rss_bytes'] / (1024**2):.1f} MB"

lines = [
    "# Issue #246 Release App 内存证据",
    "",
    "状态：Release App + SwiftUI 窗口实测。隔离 `HOME` / `CFFIXED_USER_HOME`，**不提交**真实历史 JSON / tag / token。",
    "",
    "## 环境",
    "",
    f"- commit：`{meta.get('commit')}`",
    f"- App：`{meta.get('app')}`（`{meta.get('bundle_id')}`）",
    f"- macOS：{meta.get('macos')} / {meta.get('arch')}",
    f"- Swift：{meta.get('swift')}",
    f"- idle：{meta.get('idle_seconds')} 秒",
    f"- 24 条历史：{meta.get('history_entries')} entries，{meta.get('history_bytes')} bytes（仅本地 Application Support 副本，未入库）",
    "- 1005 Wall：AppModel 导入 before/after/after 到隔离 HOME，再启动 Release App 加载并 idle",
    "",
    "## 24 条历史 load（启动 Release App → idle 5s）",
    "",
    "| pass | phys_footprint | RSS |",
    "|---|---:|---:|",
]
for i in (1, 2):
    s = d.get(f"history_load_{i}")
    lines.append(f"| {i} | {mb(s)} | {rss(s)} |")
lines += [
    "",
    "## 1005 Wall（AppModel 导入后 Release App 加载 → idle 5s，连续两次）",
    "",
    f"- 导入路径：AppModel.parseAccountText + applyPendingAccountSnapshot，然后 Release App load",
    "",
    "| pass | phys_footprint | RSS |",
    "|---|---:|---:|",
]
for i in (1, 2):
    s = d.get(f"walls_load_{i}")
    lines.append(f"| {i} | {mb(s)} | {rss(s)} |")
lines += [
    "",
    "## 门禁对照",
    "",
    "- 24 条历史不得再出现两位数 GB `phys_footprint`。",
    "- 连续两次相同 load/import 不得单调涨到 GB 级。",
    "- 本文件不含账号原文、token、cookie、原始 Tag。",
    "",
]
Path(report_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
print(report_path)
PY

log "wrote $report"
cat "$report"
