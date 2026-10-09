#!/usr/bin/env bash
#
# dtx-install.sh — one-shot worker bootstrap for Debian/Ubuntu hosts
# Usage:  sudo bash dtx-install.sh
#
set -euo pipefail

REPO_DIR="${DXT_REPO_DIR:-/opt/dist-transcode}"
REPO_URL="${DXT_REPO_URL:-https://github.com/austinleach-systems/dist-transcode.git}"
SERVICE=dtx-worker.service

echo "=== Dist Transcode Worker Setup ==="

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