#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

TARGET_IP=${1:-}
LISTEN_PORT=${2:-8080}
TARGET_PORT=${3:-8080}

if [[ -z "${TARGET_IP}" ]]; then
  echo "Usage: sudo ./install-frontend-forward.sh <NIXOS_HOST_VM_IP> [LISTEN_PORT] [TARGET_PORT]" >&2
  echo "Example: sudo ./install-frontend-forward.sh 192.168.122.50 8080 8080" >&2
  exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
  echo "Installing socat..." >&2
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y socat
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y socat
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm socat
  else
    echo "Please install 'socat' and re-run." >&2
    exit 1
  fi
fi

install -m 0644 -o root -g root "$(dirname "$0")/talos-lab-frontend-forward.service" /etc/systemd/system/talos-lab-frontend-forward.service
cat > /etc/talos-lab-frontend-forward.env <<EOF
TARGET_IP=${TARGET_IP}
TARGET_PORT=${TARGET_PORT}
LISTEN_PORT=${LISTEN_PORT}
EOF
chmod 0644 /etc/talos-lab-frontend-forward.env

systemctl daemon-reload
systemctl enable --now talos-lab-frontend-forward.service
systemctl status --no-pager -l talos-lab-frontend-forward.service || true

echo
echo "OK. From any machine on your LAN, open:" 
# Best-effort guess: show ubuntu IP(s)
if command -v hostname >/dev/null 2>&1; then
  echo "  http://$(hostname -I 2>/dev/null | awk '{print $1}'):${LISTEN_PORT}/" || true
fi
echo "Or simply:" 
echo "  http://<ubuntu-lan-ip>:${LISTEN_PORT}/"
