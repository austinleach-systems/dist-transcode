#!/usr/bin/env bash
#
# dtx-install.sh — one-shot worker bootstrap for Debian/Ubuntu hosts
# Usage:  sudo bash dtx-install.sh              # local install (clone + deps + systemd)
#         ./dtx-install.sh <remote_host>        # update remote worker git repo + restart svc
#         ./dtx-install.sh 10.0.79.8 10.0.79.20 # deploy to multiple hosts from thefarm
#
set -euo pipefail

REPO_DIR="${DXT_REPO_DIR:-/opt/dist-transcode}"
REPO_URL="${DXT_REPO_URL:-https://github.com/austinleach-systems/dist-transcode.git}"
REMOTE_USER="${DXT_REMOTE_USER:-austin}"

# Parse user@host entries from workers.txt (skip comments / blanks)
parse_workers() {
    local file="$1"
    grep -v '^#' "$file" | grep -v '^\s*$' | while IFS= read -r entry; do
        echo "$entry" | grep -oP '^[^@]+@\K.+' || true  # extract host from user@host
    done | sort -u
}

deploy_remote() {
    local target="$1"
    # Handle both bare IPs and user@host format
    local hostname="${target#*@}"
    local full_target="${target%%:*}"   # strip port if present
    
    echo ""
    echo "=== Updating worker on $hostname ==="
    
    # Use -t to allocate pty (lets sudo prompt interactively over SSH)
    ssh -t -o StrictHostKeyChecking=no "$REMOTE_USER@$hostname" \
        "set -euo pipefail; \
         REPO_DIR='$REPO_DIR'; REPO_URL='$REPO_URL'; \
         if [ ! -d \"\$REPO_DIR/.git\" ]; then \
           echo '[*] Cloning repo...'; sudo git clone '\$REPO_URL' '\$REPO_DIR'; \
         fi; \
         echo '[*] Pulling latest...'; sudo git -C '\$REPO_DIR' pull; \
         echo '[*] Restarting service...'; sudo systemctl restart dtx-worker.service" || {
            echo "ERROR: update of $hostname failed."
            return 1
        }
    
    # Verify service is running
    ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$hostname" \
        "sudo systemctl is-active dtx-worker.service" || true
}

if (( $# > 0 )); then
    workers=()
    for arg in "$@"; do
        if [[ "$arg" == "--all" ]]; then
            # Read from workers.txt in this directory
            local_wt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && echo "workers.txt")"
            if [[ ! -f "$local_wt" ]]; then
                echo "ERROR: workers.txt not found in $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                exit 1
            fi
            while IFS= read -r w; do
                [[ -n "$w" ]] && workers+=("$w")
            done < <(parse_workers "$local_wt")
            echo "[+] Found ${#workers[@]} active worker(s) in workers.txt"
        else
            workers+=("$arg")
        fi
    done
    
    if (( ${#workers[@]} == 0 )); then
        echo "ERROR: no targets specified. Use host IPs or --all to read from workers.txt."
        exit 1
    fi
    
    failed=0
    for target in "${workers[@]}"; do
        deploy_remote "$target" || (( failed++ ))
    done
    
    total=${#workers[@]}
    if (( failed > 0 )); then
        echo ""
        echo "=== Updated $((total - failed))/$total host(s), $failed failed ==="
        exit 1
    fi
    echo ""
    echo "=== All $total host(s) updated successfully ==="
    exit 0
fi

# ── Local install: require root or auto-escalate ─────────────────────
if [[ "$(id -u)" -ne 0 && "${DXT_ESCALATED:-}" != "1" ]]; then
    export DXT_ESCALATED=1
    exec sudo "$0"
fi

echo "=== Dist Transcode Worker Setup (local) ==="

# ── Clone/ensure repo exists ────────────────────────────────────────────
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "[*] Cloning dist-transcode..."
  git clone "$REPO_URL" "$REPO_DIR" || {
    echo "ERROR: git clone from $REPO_URL failed."
    exit 1
  }
fi

if [ ! -f "$REPO_DIR/worker.py" ]; then
  echo "ERROR: $REPO_DIR/worker.py missing after clone."
  exit 1
fi
echo "[+] Repo ready at $REPO_DIR."

# ── Install HandBrake + transcode-video ruby gem ────────────────────────
if ! command -v transcode-video.rb &>/dev/null; then
  echo "[*] Installing HandBrake + dependencies..."
  if [ -x /usr/bin/apt-get ]; then
    apt-get update -qq && apt-get install -y --no-install-recommends \
      handbrake-cli ruby
  elif [ -x /usr/bin/yum ]; then
    yum install -y handbrake-gui ruby
  else
    echo "ERROR: unsupported package manager. Install handbrake + ruby manually."
    exit 1
  fi
  gem install transcode-video --no-document
else
  echo "[+] HandBrake + transcode-video.rb already installed."
fi

# ── Prepare runtime dirs ───────────────────────────────────────────────
mkdir -p /dev/shm/dist_transcode

# ── Install systemd unit ───────────────────────────────────────────────
cat > /etc/systemd/system/dtx-worker.service <<'EOF'
[Unit]
Description=Distributed Transcode Worker Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/dist-transcode/worker.py
Restart=on-failure
RestartSec=5
WorkingDirectory=/opt/dist-transcode
Environment=W_PORT=9876
Environment=W_REMOTE=/dev/shm/dist_transcode
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/tmp /dev/shm/dist_transcode
PrivateTmp=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo "[✓] Unit installed."

# ── Enable + start ─────────────────────────────────────────────────────
systemctl enable dtx-worker.service
systemctl restart dtx-worker.service

echo ""
echo "=== Ready ==="
systemctl status dtx-worker.service --no-pager -l