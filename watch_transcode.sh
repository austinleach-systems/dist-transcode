#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="/dev/shm/dist_transcode"
LD='/tmp/.dtx_lock'
STATUS=false

# ── parse args ─────────────────────────────
while [[ ${1:-} == --* ]]; do
    case "$1" in
        --status) STATUS=true; shift;; *) shift;; esac
done || true

[[ -n "${1-}" ]] && INPUT="$(realpath "$1")" || die "input dir required"
[[ -n "${2-}" ]] && OUTPUT="$(realpath -m "$2")" || die "output dir required"
WORKERS_FILE="${3:-${SCRIPT}/workers.txt}"

die() { echo "[!] $*" >&2; exit 1; }
[[ -f "$WORKERS_FILE" ]] || die "No workers file: $WORKERS_FILE"

mapfile -t HW < <(sed 's/\r$//' "$WORKERS_FILE" | grep -vE '^\s*#|^\s*$')
(( ${#HW[@]} == 0 )) && die "Empty worker list after filtering."
mkdir -p "$OUTPUT" "$LD"

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT SIGINT
CL="python3 ${SCRIPT}/worker_cli.py"

# ── --status (via TCP) ──────────────────────
if $STATUS; then
    for h in "${HW[@]}"; do
        hp=$(echo "$h" | cut -d@ -f2 | cut -d: -f1)
        resp=$($CL --host "$hp" ping 2>/dev/null) || { echo "$h: OFFLINE"; continue; }
        if echo "$resp" | grep -q '"busy": true'; then
            pg=$($CL --host "$hp" status 2>/dev/null) || { echo "$h: BUSY (no data)"; continue; }
            ptext=$(echo "$pg" | grep -oP '"progress":"\K[^"]*' || echo "BUSY")
            echo "$h: $ptext"
        else
            echo "$h: IDLE"
        fi
    done
    exit 0
fi

VER="$(cd "$SCRIPT" && git log --oneline -1 --format=%h 2>/dev/null || echo unknown)"
echo "ver=$VER watch=$INPUT out=$OUTPUT workers=${#HW[@]}"

# ── one job (TCP dispatch) ──────────────
run() {
    local fp="$1" rp="$2" h hp found=false tmp_res="/tmp/.dtx_$$_${RANDOM}_resrc"

    for __ in $(seq 0 $(( ${#HW[@]} - 1 ))); do
        h="${HW[$IDX]}"
        hp=$(echo "$h" | cut -d@ -f2)
        hostip=$(echo "$hp" | cut -d: -f1)
        IDX=$(( (IDX + 1) % ${#HW[@]} ))

        resp=$($CL --host "$hostip" --silent ping 2>/dev/null) || continue
        local busy="false"
        echo "$resp" | grep -q 'true' && busy="true" || busy="false"
        [[ "$busy" == "false" ]] && found=true && break
    done

    [[ $found == true ]] || return 1

    local bn="${fp##*/}" sub stem ext
    sub=$(dirname -- "$rp")
    [[ $sub == '.' ]] && sub=''
    stem=${bn%.*}
    ext=${bn##*.}
    sub="/$sub"

    echo "[$(date +%H:%M)] $bn → $hostip ($h)"

    # Upload via SCP (still needed; TCP doesn't replace bulk file transfer)
    scp "$fp" "$h:$REMOTE/$bn" 2>/dev/null || return 1

    local rc=1
    rc=$($CL -r "$tmp_res.rc" --host "$hostip" transcode -f "$bn" 2>/dev/null; cat "$tmp_res.rc")

    if (( rc == 0 )); then
        local result="${stem}_av1.${ext}"
        mkdir -p "$OUTPUT/$sub"
        scp "$h:$REMOTE/$result" "$OUTPUT/$sub/" 2>/dev/null && echo " ok: $fp ($h)" \
            || { echo " ?? failed to copy $result" >&2; false; }
    else
        echo " FAIL: exit=$rc on $hostip" >&2
    fi

    ssh "$h" "rm -f '${REMOTE}/${bn}' '${REMOTE}/${stem}_av1.*'" 2>/dev/null || true
    rm -f "$tmp_res.rc"
}

# ── watch loop ────────────────────────
IDX=0
while :; do
    raw=$(inotifywait -rq -e close_write,moved_to --exclude '/._.*' "$INPUT" 2>/dev/null || sleep 5)
    [[ -z $raw ]] && continue

    fl="/tmp/.dtx_watcher_${$}"
    >"$fl"

    while IFS= read -r L; do
        f="${L##* }"
        case "$f" in *.mkv|*.mp4|*.avi|*.mov|*.webm) ;; *) continue;; esac
        [[ $f == *'_av1'* ]] && continue
        a="${INPUT}/${f}"
        d=$(dirname -- "$f"); [[ $d != . ]] || d=''
        printf '%s\t%s\n' "$a" "${d:+$d/}${f}"
    done <<<"$raw" | sort -u > "$fl"

    c=$(wc -l < "$fl")
    (( c == 0 )) && { rm -f $fl; continue; }
    echo ">> $c file(s)"

    while IFS=$'\t' read -r A R; do run "$A" "$R" & done < "$fl"
    wait 2>/dev/null || true
    rm -f "$fl"
done
