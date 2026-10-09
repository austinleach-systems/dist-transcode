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

deploy_remote() {
    local host="$1"
    echo ""
    echo "=== Updating worker on $host ==="
    
    # Git pull + systemctl restart on the target
    ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$host" \
        "sudo git -C '$REPO_DIR' pull && sudo systemctl restart dtx-worker.service" || {
            echo "ERROR: update of $host failed."
            return 1
        }
    
    # Verify service is running
    ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$host" \
        "sudo systemctl is-active dtx-worker.service" || true
}

if (( $# > 0 )); then
    failed=0
    for target in "$@"; do
        deploy_remote "$target" || (( failed++ ))
    done
    if (( failed > 0 )); then
        echo ""
        echo "=== Updated $(($# - failed))/$# host(s), $failed failed ==="
        exit 1
    fi
    echo ""
    echo "=== All $# host(s) updated successfully ==="
    exit 0
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