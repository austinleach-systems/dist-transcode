#!/usr/bin/env bash
# watch_transcode.sh — Watch for new video files and farm transcoding across
# remote workers over SSH. Each worker runs one job at a time since the
# Ruby CLI saturates all available cores.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="${1:-~/videos}"
OUTPUT_DIR="${2:-~/output}"
WORKERS_FILE="${3:-${SCRIPT_DIR}/workers.txt}"
REMOTE_TMP="/dev/shm/dist_transcode" # tmpfs-backed for faster I/O
LOCK_DIR="/tmp/.dist_transcode_locks"

# ─── Prereqs check ─────────────────────────────────────
missing=()
[[ ! -f "$WORKERS_FILE" ]] && missing+=("$WORKERS_FILE")
command -v ssh         &>/dev/null || missing+=("ssh")
command -v scp         &>/dev/null || missing+=("scp")
command -v inotifywait &>/dev/null || missing+=("inotifywait (apt install inotify-tools)")

if (( ${#missing[@]} )); then
    printf '[!] Missing: %s\n' "${missing[*]}" >&2; exit 1
fi

INPUT_DIR="$(realpath "$INPUT_DIR")"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_DIR" "$LOCK_DIR"

trap 'kill 0 2>/dev/null || true' EXIT

echo "[+] Watching : $INPUT_DIR"
echo "[+] Output   : $OUTPUT_DIR"
echo "[+] Workers  : $(grep -cve '^\s*#|^\s*$' "$WORKERS_FILE") host(s)"
echo ""

# ─── Worker list ────────────────────────────────────────
mapfile -t WORKERS < <(grep -vE '^\s*#|^\s*$' "$WORKERS_FILE" | sort -u)
NUM_WORKERS=${#WORKERS[@]}
(( NUM_WORKERS == 0 )) && { echo "[E] No workers found"; exit 1; }

worker_idx=0

pick_worker() {
    local w i
    for ((i = 0; i < NUM_WORKERS; i++)); do
        w="${WORKERS[$(( (worker_idx + i) % NUM_WORKERS ))]}"
        ! [[ -f "${LOCK_DIR}/${w//\//_}" ]] && break
    done
    worker_idx=$(( (worker_idx + 1) % NUM_WORKERS ))
    echo "$w"
}

# ─── Transcode one file on chosen worker ────────────────
# Args: ABS_PATH REL_PATH
do_job() {
    local abs="$1" rel="$2"
    local host
    host="$(pick_worker)"

    printf '%s' $$ > "${LOCK_DIR}/${host//\//_}"

    local bname="${abs##*/}"
    local sub="$(dirname "$rel")"
    [[ "$sub" == "." ]] && sub=""

    echo "[$(date +%H:%M)] ship $bname → $host"

    # Ship to worker temp (use absolute local path directly)
    ssh "$host" "mkdir -p '${REMOTE_TMP}'" 2>/dev/null || true
    if ! scp "$abs" "${host}:${REMOTE_TMP}/${bname}" 2>/dev/null; then
        echo "[!] SCP failed: $abs → $host"; rm -f "${LOCK_DIR}/${host//\//_}"; return
    fi

    # Transcode on worker (show stderr to diagnose failures)
    if ssh "$host" "cd '${REMOTE_TMP}' && transcode-video.rb -m av1 '${bname}'" 2>&1; then
        local ext="${bname##*.}" stem="${bname%.*}" result="${stem}_av1.${ext}"

        mkdir -p "${OUTPUT_DIR}/${sub}"
        if scp "${host}:${REMOTE_TMP}/${result}" "${OUTPUT_DIR}/${sub}/" 2>/dev/null; then
            echo "[ok] $rel ✓ ($host)"
        else
            echo "[!] copy-back failed from $host: $result" >&2
        fi

        # Cleanup worker temp
        ssh "$host" "rm -f '${REMOTE_TMP}/${bname}' '${REMOTE_TMP}/${result}'" 2>/dev/null || true
    else
        echo "[!] transcode ERR on $host: $rel" >&2
    fi

    rm -f "${LOCK_DIR}/${host//\//_}"
}

# ─── Main loop ──────────────────────────────────────────
while true; do

    new_files=$(inotifywait -re close_write,moved_to --exclude '/._.*' "$INPUT_DIR" 2>/dev/null || sleep 5)
    [[ -z "$new_files" ]] && continue

    flist=/tmp/.dt_flist.$$
    : > "$flist"

    while IFS= read -r line; do
        fpath="${line##* }"          # inotifywait: DIR EVENT FILE
        case "${fpath}" in
            *.mkv|*.mp4|*.avi|*.mov|*.webm|*.m4v) ;;
            *) continue ;;
        esac
        [[ "$fpath" == *_av1* ]] && continue

        # fpath is relative to watch dir; rebuild abs & sub
        abs="${INPUT_DIR}/${fpath}"
        sub="$(dirname "$fpath")"
        [[ "$sub" == "." ]] && sub=""
        printf '%s\t%s\n' "$abs" "${sub:+$sub/}${fpath}"
    done <<< "$new_files" | sort -u > "$flist"

    cnt=$(wc -l < "$flist")
    (( cnt == 0 )) && { rm -f "$flist"; continue; }

    echo "=== $cnt new file(s) detected ==="

    while IFS=$'\t' read -r abspath relpath; do
        do_job "$abspath" "$relpath" &
    done < "$flist"

    wait 2>/dev/null || true
    rm -f "$flist"
done
