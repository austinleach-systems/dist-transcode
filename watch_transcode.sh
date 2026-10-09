#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="/dev/shm/dist_transcode"
LD='/tmp/.dtx_lock'
STATUS=false
BOOTSTRAP=false

# ── parse args ────────────────────────
while [[ ${1:-} == --* ]]; do
    case "$1" in
        --status)    STATUS=true;  shift;;
        --bootstrap) BOOTSTRAP=true; shift;;
        *) shift;; esac
done || true

[[ -n "${1-}" ]] && INPUT="$(realpath "$1")"     || die "input dir required"
[[ -n "${2-}" ]] && OUTPUT="$(realpath -m "$2")" || die "output dir required"
WORKERS_FILE="${3:-${SCRIPT}/workers.txt}"

die() { echo "[!] $*" >&2; exit 1; }
[[ -f "$WORKERS_FILE" ]] || die "No workers file: $WORKERS_FILE"

mapfile -t HW < <(sed 's/\r$//' "$WORKERS_FILE" | grep -vE '^\s*#|^\s*$')
(( ${#HW[@]} == 0 )) && die "Empty worker list after filtering."
mkdir -p "$OUTPUT" "$LD"

CL="python3 ${SCRIPT}/worker_cli.py"
NWORK=${#HW[@]}

# ── atomic round-robin (shared file + flock so background jobs coordinate) ────
rr_file="/tmp/.dtx_rr_${$}"
echo 0 > "$rr_file"
rr_pick() {
    (
        flock -x 9
        local val=$(cat "$rr_file")
        local idx=$(( (val + 1) % NWORK ))
        echo "$idx" > "$rr_file"
        echo "${HW[$idx]}"
    ) 9>"${rr_file}.lock"
}

# ── signal handler: kill children AND exit the loop ────
trap 'rm -f "$rr_file" "${rr_file}.lock"; kill 0; exit' INT TERM QUIT

# ── --status (via TCP) ────────────────────────
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

# ── one job (TCP dispatch) ────────────────
run() {
    local fp="$1" rp="$2" h hp found=false tmp_res="/tmp/.dtx_$$_${RANDOM}_resrc"

    # Pick an idle worker via file-backed atomic round-robin (survives fork)
    local tried=0
    while (( tried < NWORK )); do
        h=$(rr_pick) || return 1
        hp=$(echo "$h" | cut -d@ -f2)
        hostip=$(echo "$hp" | cut -d: -f1)

        resp=$($CL --host "$hostip" --silent ping 2>/dev/null) || { tried=$((tried+1)); continue; }
        local busy="false"
        echo "$resp" | grep -q 'true' && busy="true" || busy="false"
        [[ "$busy" == "false" ]] && break
        tried=$((tried+1))
    done

    (( tried >= NWORK )) && return 1

    local bn="${fp##*/}" sub stem ext
    sub=$(dirname -- "$rp")
    [[ $sub == '.' ]] && sub=''
    stem=${bn%.*}
    ext=${bn##*.}
    if [[ -n "$sub" ]]; then
        sub="/$sub"
    else
        sub=""
    fi

    echo "[$(date +%H:%M)] $bn → $hostip ($h)"

    # Upload via SCP (TCP doesn't replace bulk file transfer)
    scp "$fp" "$h:$REMOTE/$bn" 2>/dev/null || return 1

    local rc=0
    rc=$($CL -r "$tmp_res" --host "$hostip" transcode -f "$bn" 2>/dev/null; cat "${tmp_res}.rc")

    if (( rc == 0 )); then
        local result="${stem}_av1.${ext}"
        mkdir -p "$OUTPUT/$sub"
        scp "$h:$REMOTE/$result" "$OUTPUT/$sub/" 2>/dev/null && echo " ok: $fp ($h)" \
            || { echo " ?? failed to copy $result" >&2; false; }
    else
        echo " FAIL: exit=$rc on $hostip" >&2
    fi

    # Cleanup worker side
    ssh "$h" "rm -f '${REMOTE}/${bn}' '${REMOTE}/${stem}_av1.*'" 2>/dev/null || true
    rm -f "$tmp_res.rc"
}

# ── bootstrap scan (existing unencoded files) ────────
if $BOOTSTRAP; then
    echo "[*] Bootstrapping: scanning for unencoded files..."
    boot_fl="/tmp/.dtx_bootstrap_${$}"
    : >"$boot_fl"

    while IFS= read -r fl; do
        bn="${fl##*/}"
        [[ "$bn" == *_av1.* ]] && continue
        ext="${bn##*.}"
        case "$ext" in mp4|mkv|avi|mov|webm) ;; *) continue;; esac
        stem="${bn%.*}"
        outfile="$OUTPUT/${stem}_av1.${ext}"
        [[ -f "$outfile" ]] && continue  # already encoded
        printf '%s\t%s\n' "$fl" "${fl#$INPUT/}"
    done < <(find "$INPUT" -maxdepth 2 -type f \( \
        -name '*.mp4' -o -name '*.mkv' -o -name '*.avi' \
        -o -name '*.mov' -o -name '*.webm' \) 2>/dev/null \
    ) | sort -u > "$boot_fl"

    c=$(wc -l < "$boot_fl")
    if (( c > 0 )); then
        echo "[*] Found $c unencoded files"
        # dispatch max 4 parallel to avoid overwhelming all workers at once
        while IFS=$'\t' read -r a r; do
            run "$a" "$r" &
            jobs_count=$(jobs -rp | wc -l)
            (( jobs_count >= ${#HW[@]} )) && { wait -n 2>/dev/null || true; }
        done < "$boot_fl"
        wait 2>/dev/null || true
    else
        echo "[*] No unencoded files found for bootstrap"
    fi
    rm -f "$boot_fl"
fi

# ── watch loop (monitored, batched) ────────
while :; do
    # -m keeps inotifywait running and captures all events until timeout
    raw=$(timeout 15 inotifywait -mrq -e close_write,moved_to --exclude '/._.*' \
            --format '%w%f' "$INPUT" 2>/dev/null || sleep 5)
    [[ -z $raw ]] && continue

    fl="/tmp/.dtx_watcher_${$}"
    : >"$fl"

    while IFS= read -r filepath; do
        bn="${filepath##*/}"
        case "$bn" in *.mkv|*.mp4|*.avi|*.mov|*.webm) ;; *) continue;; esac
        [[ $bn == *'_av1'* ]] && continue
        rel="${filepath#$INPUT/}"
        subdir=$(dirname -- "$rel"); [[ $subdir != '.' ]] || subdir=''
        printf '%s\t%s\n' "$filepath" "${subdir:+$subdir/}${bn}"
    done <<<"$raw" | sort -u > "$fl"

    c=$(wc -l < "$fl")
    (( c == 0 )) && { rm -f "$fl"; continue; }
    echo ">> $c file(s)"

    while IFS=$'\t' read -r a r; do run "$a" "$r" & done < "$fl"
    wait 2>/dev/null || true
    rm -f "$fl"
done
