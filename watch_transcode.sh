#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKERS_FILE=""
REMOTE="/dev/shm/dist_transcode"
LD='/tmp/.dtx_lock'  # lock dir
STATUS=false         # --status mode

# ── parse args ─────────────────────────────
while [[ ${1:-} == --* ]]; do
    case "$1" in
        --status) STATUS=true; shift;;
        *) shift;;
    esac
done || true
[[ -n ${1-} ]] && INPUT="$(realpath "$1")" || INPUT="~/videos"
[[ -n ${2-} ]] && OUTPUT="$(realpath -m "${2}")"  || OUTPUT="~/output"
if [[ -n ${3-} ]]; then WORKERS_FILE="$3"; else WORKERS_FILE="${SCRIPT}/workers.txt"; fi

# ── check ──────────────────────────────────
must() { command -v "$1" &>/dev/null || die "need $1"; }
die()  { echo "[!] $*" >&2; exit 1; }
[[ -f "$WORKERS_FILE" ]] || die "No workers file: $WORKERS_FILE"
mapfile -t HW < <(sed 's/\r$//' "$WORKERS_FILE" | grep -vE '^\s*#|^\s*$')
(( ${#HW[@]} == 0 )) && die "Empty worker list"
mkdir -p "$OUTPUT" "$LD"

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT SIGINT

# ── --status ───────────────────────────────
if $STATUS; then
    for h in "${HW[@]}"; do s="${h//\//_}";
        if [[ -d "$LD/$s" ]]; then
            ssh "$h" 'grep "Encoding:" /tmp/.dtx_prog.txt 2>/dev/null | tail -1 || echo "BUSY"' \
                2>/dev/null || echo "$h: BUSY (no data)"
        else ssh "$h" true 2>/dev/null && echo "$h: IDLE" || echo "$h: OFFLINE"; fi
    done; exit 0
fi

VERSION_COMMIT="$(cd "$SCRIPT" && git log --oneline -1 --format=%h 2>/dev/null || echo unknown)"
echo "ver=$VERSION_COMMIT watch=$INPUT out=$OUTPUT workers=${#HW[@]}"

# ── one job ────────────────────────────────
run() {
    local fp="$1" rp="$2" h s lock
    local found=false
    for __ in $(seq 0 $(( ${#HW[@]} - 1 ))); do
        h="${HW[$IDX]}"
        s="${h//\//_}"; lock="$LD/$s"
        IDX=$(( (IDX + 1) % ${#HW[@]} ))
        if mkdir "$lock" 2>/dev/null; then found=true; break; fi
    done || true
    [[ $found == true ]] || return 1  # all busy

    local bn=${fp##*/} sub=$(dirname -- "$rp")
    [[ $sub == '.' ]] && sub=''
    echo "[$(date +%H:%m)] $bn → $h"

    ssh "$h" "mkdir -p '$REMOTE'" 2>/dev/null || true
    scp "$fp" "$h:$REMOTE/$bn"     2>/dev/null || { rm -rf "$lock"; return; }

    # Encode — output streams live (not captured); pipefail gives us transcode's rc
    local _encode_rc=1
    ssh "$h" "cd '$REMOTE' && set -o pipefail && \
        transcode-video.rb -m av1 \"\$bn\" 2>&1 | tee /tmp/.dtx_prog.txt" \
        && _encode_rc=0 || true
    local rc=$_encode_rc

    if (( rc == 0 )); then
        local ext=${bn##*.} stem=${bn%.*} result="${stem}_av1.${ext}"
        mkdir -p "$OUTPUT/$sub"
        scp "$h:$REMOTE/$result" "$OUTPUT/$sub/" 2>/dev/null && echo " ok: $rp ($h)" \
            || echo " ?? copy $result from $h" >&2
    else
        echo " FAIL: $rp on $h (rc=$rc)" >&2; fi

    ssh "$h" "rm -f '$REMOTE/$bn' '$REMOTE/${stem:-x}_av1.*'" 2>/dev/null || true
    rm -rf "$lock"
}

# ── loop ───────────────────────────────────
IDX=0
while :; do
    raw=$(inotifywait -rq -e close_write,moved_to --exclude '/._.*' "$INPUT" 2>/dev/null || sleep 5)
    [[ -z $raw ]] && continue
    fl=/tmp/.dtx_$$_fl
    >$fl

    while IFS= read -r L; do
        f=${L##* }                        # last field = path
        case "$f" in *.mkv|*.mp4|*.avi|*.mov|*.webm) ;; *) continue;; esac
        [[ $f == *'_av1'* ]] && continue
        a="${INPUT}/${f}"               # abspath
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