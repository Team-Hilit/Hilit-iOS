#!/usr/bin/env bash
# 실기기 QA 보조 — devicectl 로 앱 실행·강제 종료·스크린샷·앱 컨테이너 수집을 묶는다.
# 시뮬레이터로 못 보는 녹화 보관·재개 케이스(HLT-78 등)의 «손으로 컨테이너 내려받기» 단계를 대신한다.
# 사용법: docs/device-qa.md
set -euo pipefail

BUNDLE="${BUNDLE:-com.hilit.app.dev}"
APP_NAME="${APP_NAME:-Hilit}"
OUT_ROOT="${OUT_ROOT:-.device-qa}"
RUN_DIR="${RUN_DIR:-$OUT_ROOT/$(date +%Y%m%d-%H%M%S)}"
# 실기기 잠금 — 여러 세션(worktree)이 한 기기에 같은 번들을 덮어 설치·종료하지 않게 한다.
LOCK_DIR="${DEVICE_QA_LOCK:-/tmp/hilit-device-qa.lock}"

die() { echo "❌ $*" >&2; exit 1; }
log() { echo "▸ $*" >&2; }

# ── 기기 해석 ─────────────────────────────────────────────────────────────
# DEVICE 가 없으면 연결된 실기기 하나를 고른다. 시뮬레이터 UDID 를 주면 simctl 경로로 동작한다
# (devicectl 의 파일 전송은 시뮬레이터 미지원 — 컨테이너는 호스트 경로에서 바로 복사).

list_devices_json() {
    local tmp; tmp="$(mktemp)"
    xcrun devicectl list devices -j "$tmp" >/dev/null 2>&1 || true
    cat "$tmp"; rm -f "$tmp"
}

resolve_device() {
    if [[ -n "${DEVICE:-}" ]]; then echo "$DEVICE"; return; fi
    local ids
    ids="$(list_devices_json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
for x in d.get("result", {}).get("devices", []):
    hw = x.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS":
        print(x.get("hardwareProperties", {}).get("udid") or x.get("identifier"))
')"
    local n; n="$(printf '%s' "$ids" | grep -c . || true)"
    [[ "$n" == "1" ]] || die "연결된 실기기 ${n}대 — DEVICE=<udid|이름> 로 지정하세요 (목록: $0 devices)"
    echo "$ids"
}

is_simulator() { xcrun simctl list devices | grep -qF "($1)"; }

# 기기를 쓰는 명령은 이걸로 기기를 얻는다 — 실기기면 잠금을 잡는다(시뮬레이터는 세션마다 따로라 생략).
use_device() {
    local dev; dev="$(resolve_device)"
    is_simulator "$dev" || acquire_lock
    echo "$dev"
}

# ── 잠금 ─────────────────────────────────────────────────────────────────
# 주인 = 현재 브랜치(worktree 마다 다름). 잡은 쪽이 unlock 할 때까지 유지 — 시나리오 도중 끼어들기를 막는다.

lock_owner() { git branch --show-current 2>/dev/null || basename "$PWD"; }

acquire_lock() {
    local me; me="$(lock_owner)"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n%s\n' "$me" "$(date '+%m-%d %H:%M')" >"$LOCK_DIR/owner"
        log "기기 잠금: $me (끝나면 $0 unlock)"
        return
    fi
    local holder since
    holder="$(sed -n 1p "$LOCK_DIR/owner" 2>/dev/null || true)"
    since="$(sed -n 2p "$LOCK_DIR/owner" 2>/dev/null || true)"
    [[ "$holder" == "$me" ]] && return
    die "기기 사용 중: ${holder:-알 수 없음} (${since:-?} 부터). 그쪽이 끝나고 unlock 하면 다시 시도"
}

cmd_lock() {
    local dev; dev="$(resolve_device)"
    is_simulator "$dev" && { log "시뮬레이터는 잠금 불필요"; return; }
    acquire_lock
}

cmd_unlock() {
    [[ -d "$LOCK_DIR" ]] || { log "잠금 없음"; return; }
    local holder; holder="$(sed -n 1p "$LOCK_DIR/owner" 2>/dev/null || true)"
    if [[ "$holder" != "$(lock_owner)" && "${1:-}" != "--force" ]]; then
        die "주인이 $holder — 내 잠금이 아님 (정말 풀려면 unlock --force)"
    fi
    rm -rf "$LOCK_DIR"
    log "기기 잠금 해제"
}

cmd_status() {
    if [[ -d "$LOCK_DIR" ]]; then
        echo "사용 중: $(sed -n 1p "$LOCK_DIR/owner") ($(sed -n 2p "$LOCK_DIR/owner") 부터)"
    else
        echo "비어 있음"
    fi
}

# ── 명령 ─────────────────────────────────────────────────────────────────

cmd_devices() {
    xcrun devicectl list devices
}

cmd_install() {
    local app="${1:-}"; [[ -d "$app" ]] || die "사용: $0 install <path/to/Hilit.app>"
    local dev; dev="$(use_device)"
    if is_simulator "$dev"; then xcrun simctl install "$dev" "$app"
    else xcrun devicectl device install app -d "$dev" "$app"; fi
}

cmd_launch() {
    local dev; dev="$(use_device)"
    if is_simulator "$dev"; then xcrun simctl launch --terminate-running-process "$dev" "$BUNDLE" >/dev/null
    else xcrun devicectl device process launch -q -d "$dev" --terminate-existing "$BUNDLE"; fi
    log "실행: $BUNDLE"
}

# 앱 PID — 실기기는 실행 파일 경로(…/Hilit.app/Hilit)로, 시뮬레이터는 launchctl 라벨로 찾는다.
app_pid() {
    local dev="$1"
    if is_simulator "$dev"; then
        xcrun simctl spawn "$dev" launchctl list 2>/dev/null \
            | awk -v b="UIKitApplication:$BUNDLE[" 'index($3, b) == 1 && $1 != "-" { print $1; exit }'
        return
    fi
    local tmp; tmp="$(mktemp)"
    xcrun devicectl device info processes -d "$dev" -j "$tmp" >/dev/null 2>&1 || true
    python3 -I - "$tmp" "$APP_NAME" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
suffix = f"/{sys.argv[2]}.app/{sys.argv[2]}"
for p in d.get("result", {}).get("runningProcesses", []):
    if p.get("executable", "").endswith(suffix):
        print(p["processIdentifier"]); break
PY
    rm -f "$tmp"
}

# 강제 종료 — 앱 전환기에서 쓸어 올린 것과 같은 SIGKILL. 마감 코드가 전혀 돌지 않는 경로를 재현한다.
cmd_kill() {
    local dev; dev="$(use_device)"
    local pid; pid="$(app_pid "$dev")"
    [[ -n "$pid" ]] || die "$BUNDLE 실행 중 아님"
    if is_simulator "$dev"; then kill -9 "$pid"
    else xcrun devicectl device process signal -q -d "$dev" --pid "$pid" --signal SIGKILL; fi
    log "SIGKILL pid=$pid"
}

cmd_shot() {
    local name="${1:-shot}"; local dev; dev="$(use_device)"
    mkdir -p "$RUN_DIR"
    local dst="$RUN_DIR/$name.png"
    if is_simulator "$dev"; then xcrun simctl io "$dev" screenshot "$dst" >/dev/null 2>&1
    else xcrun devicectl device capture screenshot -q -d "$dev" --destination "$dst"; fi
    log "스크린샷: $dst"
}

# 컨테이너 수집 — tmp·Application Support·Preferences 만 (Caches 등은 크기만 크고 판정에 안 쓴다).
cmd_pull() {
    local name="${1:-pull}"; local dev; dev="$(use_device)"
    local dst="$RUN_DIR/$name"
    mkdir -p "$dst"
    if is_simulator "$dev"; then
        local root; root="$(xcrun simctl get_app_container "$dev" "$BUNDLE" data)" || die "$BUNDLE 미설치"
        for p in tmp "Library/Application Support" Library/Preferences; do
            [[ -d "$root/$p" ]] && mkdir -p "$dst/$(dirname "$p")" && cp -R "$root/$p" "$dst/$p"
        done
    else
        for p in tmp "Library/Application Support" Library/Preferences; do
            mkdir -p "$dst/$(dirname "$p")"
            xcrun devicectl device copy from -q -d "$dev" \
                --domain-type appDataContainer --domain-identifier "$BUNDLE" \
                --source "$p" --destination "$dst/$p" 2>/dev/null || log "건너뜀(없음): $p"
        done
    fi
    log "컨테이너: $dst"
    report "$dst"
}

# 판정용 요약 — 녹화 조각·원장·held 세션.
report() {
    python3 -I - "$1" "$BUNDLE" <<'PY'
import json, os, plistlib, sys
root, bundle = sys.argv[1], sys.argv[2]
print(f"── {root}")
hits = []
for base, _, files in os.walk(root):
    for f in files:
        if f.startswith("interview-"):
            p = os.path.join(base, f)
            hits.append((os.path.relpath(p, root), os.path.getsize(p)))
print("녹화 파일:" if hits else "녹화 파일: 없음")
for rel, size in sorted(hits):
    print(f"  {size:>12,d}  {rel}")
for rel, _ in sorted(hits):
    if rel.endswith(".json"):
        print(f"원장 {rel}:")
        try:
            print("  " + json.dumps(json.load(open(os.path.join(root, rel))), ensure_ascii=False)[:2000])
        except Exception as e:
            print(f"  읽기 실패: {e}")
pref = os.path.join(root, "Library/Preferences", f"{bundle}.plist")
held = None
if os.path.exists(pref):
    raw = plistlib.load(open(pref, "rb")).get("interview.heldSession.v1")
    if raw is not None:
        held = json.loads(raw) if isinstance(raw, (bytes, bytearray)) else raw
print("held 세션: " + (json.dumps(held, ensure_ascii=False) if held is not None else "없음"))
PY
}

# 파일럿 — 녹화 중 강제 종료 후 보관·재개 확인 (HLT-78). 면접 진행 조작은 사람이 한다.
cmd_force_kill() {
    local dev; dev="$(use_device)"; export DEVICE="$dev"
    log "결과 폴더: $RUN_DIR"
    cmd_launch
    read -r -p "면접을 시작해 녹화 중 상태로 만든 뒤 Enter (답변 중이면 됨) " _
    cmd_shot 1-before-kill
    cmd_kill
    sleep 2
    cmd_pull 2-after-kill
    cmd_launch
    read -r -p "홈 «이어서 진행» 카드가 보이면 Enter (안 보여도 Enter) " _
    cmd_shot 3-home-after-relaunch
    read -r -p "[이어서 진행] → 녹화가 다시 시작되면 Enter " _
    cmd_shot 4-resumed
    cmd_pull 4-resumed
    log "끝 — $RUN_DIR 의 스크린샷·요약으로 판정"
}

usage() {
    cat <<EOF
사용: [DEVICE=<udid|이름>] [BUNDLE=$BUNDLE] $0 <명령>
  devices              연결 기기 목록
  install <app>        .app 설치
  launch               앱 실행 (기존 인스턴스 종료)
  kill                 앱 강제 종료 (SIGKILL)
  shot [이름]          스크린샷 → \$RUN_DIR/<이름>.png
  pull [이름]          컨테이너(tmp·Application Support·Preferences) 수집 + 녹화 파일·held 요약
  force-kill           파일럿: 녹화 중 강제 종료 → 수집 → 재실행·재개 → 수집 (HLT-78)
  lock / unlock [--force] / status
                       실기기 잠금 — 기기를 쓰는 명령은 자동으로 잡고, 끝나면 unlock 으로 반납
결과: \$RUN_DIR (기본 $OUT_ROOT/<시각>)
EOF
}

case "${1:-}" in
    devices) cmd_devices ;;
    install) shift; cmd_install "$@" ;;
    launch) cmd_launch ;;
    kill) cmd_kill ;;
    shot) shift; cmd_shot "$@" ;;
    pull) shift; cmd_pull "$@" ;;
    force-kill) cmd_force_kill ;;
    lock) cmd_lock ;;
    status) cmd_status ;;
    unlock) shift; cmd_unlock "$@" ;;
    *) usage; exit 1 ;;
esac
