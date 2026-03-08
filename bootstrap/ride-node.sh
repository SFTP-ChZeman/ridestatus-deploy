#!/usr/bin/env bash
# =============================================================================
# RideStatus — Ride Edge Node Bootstrap Script
# =============================================================================
# Provisions a fresh Debian 12 VM as a RideStatus Ride Edge Node.
# Installs Node.js 22, PM2, Node-RED, SQLite, and ridestatus-ride.
#
# Usage:    sudo bash ride-node.sh
# Requires: /opt/ridestatus/ride-node.env
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/common.sh"

ENV_FILE="/opt/ridestatus/ride-node.env"

if [[ ! -f "$ENV_FILE" ]]; then
  log_error "Environment file not found: $ENV_FILE"
  log_error "Copy ride-node.env.example to $ENV_FILE and fill in values."
  exit 1
fi
source "$ENV_FILE"

log_info "=== RideStatus Ride Edge Node Bootstrap ==="
log_info "Ride: ${RIDE_NAME:-UNKNOWN}  PLC: ${PLC_IP:-UNKNOWN} (${PLC_PROTOCOL:-UNKNOWN})"

apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq curl git sqlite3 ufw build-essential

install_nodejs 22

log_info "Installing PM2..."
npm install -g pm2 --silent
pm2 startup systemd -u ridestatus --hp /home/ridestatus | tail -1 | bash || true

log_info "Installing Node-RED..."
npm install -g --unsafe-perm node-red --silent

if ! id ridestatus &>/dev/null; then
  useradd -r -m -d /home/ridestatus -s /usr/sbin/nologin ridestatus
fi

APP_DIR="/opt/ridestatus/ride"
mkdir -p "$APP_DIR"

# TODO: Replace with your deployment method. Options:
# A) git clone:  GIT_SSH_COMMAND="ssh -i /etc/ridestatus/deploy_key" \
#                  git clone git@github.com:SFTP-ChZeman/ridestatus-ride.git "$APP_DIR"
# B) Pull release tarball from artifact server
log_warn "Application deployment step is a placeholder — see ride-node.sh comments."

configure_firewall_ride_node

if [[ -f "$APP_DIR/ecosystem.config.js" ]]; then
  sudo -u ridestatus pm2 start "$APP_DIR/ecosystem.config.js"
  sudo -u ridestatus pm2 save
else
  log_warn "ecosystem.config.js not found — PM2 processes not started."
fi

log_info "=== Ride Edge Node Bootstrap Complete ==="
