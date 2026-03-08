#!/usr/bin/env bash
# =============================================================================
# RideStatus — Ansible Controller Bootstrap
# https://github.com/RideStatus/ridestatus-deploy
#
# Run inside the Ansible Controller VM after creation by deploy.sh.
# Can also be run manually to re-bootstrap or repair an existing install.
#
# What this script does:
#   1. Installs system packages (Ansible, chrony, git, curl, jq)
#   2. Configures chrony to sync from internet NTP pool (stratum 2,
#      independent of the RideStatus Server VM)
#   3. Ensures the 'ridestatus' OS user exists with correct home/permissions
#   4. Generates the Ansible SSH keypair used to manage all nodes
#      (/home/ridestatus/.ssh/ansible_ridestatus)
#      — This key is installed into every edge node and the server VM
#        by their respective bootstrap scripts.
#   5. Clones ridestatus-deploy repo to /home/ridestatus/ridestatus-deploy
#   6. Writes a starter Ansible inventory (populated as nodes are added)
#   7. Installs a systemd timer for the health-check playbook (every 5 min)
#   8. Prints the Ansible public key — record this for server.sh
#
# Usage (called by deploy.sh via SSH, or manually):
#   curl -fsSL https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap/ansible.sh | sudo bash
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[ansible.sh]${RESET} $*"; }
ok()     { echo -e "${GREEN}[ansible.sh]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[ansible.sh]${RESET} $*"; }
die()    { echo -e "${RED}[ansible.sh] ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo bash ansible.sh)"

RS_USER="ridestatus"
RS_HOME="/home/${RS_USER}"
DEPLOY_REPO="https://github.com/RideStatus/ridestatus-deploy.git"
DEPLOY_DIR="${RS_HOME}/ridestatus-deploy"
ANSIBLE_KEY="${RS_HOME}/.ssh/ansible_ridestatus"
INVENTORY_DIR="${RS_HOME}/inventory"
LOG_DIR="${RS_HOME}/logs"

# =============================================================================
# 1. System packages
# =============================================================================
header "Installing System Packages"

apt-get update -qq
apt-get install -y --no-install-recommends \
  ansible \
  chrony \
  git \
  curl \
  jq \
  python3 \
  python3-pip \
  openssh-client

# ansible-lint is useful but optional — don't fail if pip is restricted
pip3 install --quiet ansible-lint 2>/dev/null || true

ok "Packages installed"

# =============================================================================
# 2. Chrony — sync from internet NTP pool
# The Ansible VM has external internet access and syncs independently
# (stratum 2, same as the Server VM). This avoids a dependency on the
# Server VM being up for the Ansible VM to have accurate time.
# =============================================================================
header "Configuring NTP (chrony)"

cat > /etc/chrony/chrony.conf << 'EOF'
# RideStatus Ansible Controller — chrony config
# Syncs from internet NTP pool (stratum 2, independent of Server VM)

pool pool.ntp.org iburst minpoll 6 maxpoll 10

# Allow local clients on loopback only
allow 127.0.0.1
allow ::1

# Clock discipline settings
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF

systemctl enable chrony
systemctl restart chrony

# Wait up to 30s for initial sync
for i in $(seq 1 6); do
  chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal' && break
  sleep 5
done
chronyc tracking | grep 'Leap status' || warn "chrony not yet synced — may need internet route"

ok "chrony configured"

# =============================================================================
# 3. ridestatus OS user
# =============================================================================
header "Ensuring ridestatus User"

if ! id "$RS_USER" &>/dev/null; then
  useradd -m -s /bin/bash -d "$RS_HOME" "$RS_USER"
  ok "User ${RS_USER} created"
else
  info "User ${RS_USER} already exists"
fi

mkdir -p \
  "${RS_HOME}/.ssh" \
  "${INVENTORY_DIR}" \
  "${LOG_DIR}"

chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"

ok "Home directory ready: ${RS_HOME}"

# =============================================================================
# 4. Ansible SSH keypair
# Generated once. If the key already exists it is left intact — re-running
# this script does not rotate the key (would break existing node access).
# To deliberately rotate: delete the key files and re-run.
# =============================================================================
header "Ansible SSH Keypair"

if [[ -f "${ANSIBLE_KEY}" ]]; then
  warn "Ansible keypair already exists at ${ANSIBLE_KEY} — leaving intact"
  warn "To rotate: rm ${ANSIBLE_KEY} ${ANSIBLE_KEY}.pub and re-run"
else
  sudo -u "$RS_USER" ssh-keygen \
    -t ed25519 \
    -f "${ANSIBLE_KEY}" \
    -N "" \
    -C "ansible@ridestatus" \
    -q
  chmod 600 "${ANSIBLE_KEY}"
  chmod 644 "${ANSIBLE_KEY}.pub"
  ok "Keypair generated: ${ANSIBLE_KEY}"
fi

# =============================================================================
# 5. Clone ridestatus-deploy repo
# =============================================================================
header "Cloning ridestatus-deploy"

if [[ -d "${DEPLOY_DIR}/.git" ]]; then
  info "Repo already cloned — pulling latest"
  sudo -u "$RS_USER" git -C "$DEPLOY_DIR" pull --ff-only
else
  sudo -u "$RS_USER" git clone "$DEPLOY_REPO" "$DEPLOY_DIR"
  ok "Repo cloned to ${DEPLOY_DIR}"
fi

# =============================================================================
# 6. Ansible configuration and starter inventory
# =============================================================================
header "Ansible Configuration"

# ansible.cfg — scoped to the ridestatus-deploy working directory
cat > "${DEPLOY_DIR}/ansible.cfg" << EOF
[defaults]
inventory          = ${INVENTORY_DIR}/hosts.yml
remote_user        = ridestatus
private_key_file   = ${ANSIBLE_KEY}
host_key_checking  = False
retry_files_enabled = False
stdout_callback    = yaml
callback_whitelist = timer, profile_tasks
log_path           = ${LOG_DIR}/ansible.log

[ssh_connection]
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s
EOF
chown "${RS_USER}:${RS_USER}" "${DEPLOY_DIR}/ansible.cfg"

# Starter inventory — populated by server.sh and edge-init.sh as nodes join
# The server and ansible VMs themselves are included for self-management.
if [[ ! -f "${INVENTORY_DIR}/hosts.yml" ]]; then
  cat > "${INVENTORY_DIR}/hosts.yml" << 'EOF'
---
# RideStatus Ansible Inventory
# This file is managed by bootstrap scripts and the RideStatus server admin UI.
# Add nodes manually only if needed — prefer using edge-init.sh.

all:
  vars:
    ansible_user: ridestatus
    ansible_become: true

  children:
    servers:
      hosts: {}
      # Example:
      # ridestatus-server:
      #   ansible_host: 10.15.140.101

    ansible_controllers:
      hosts: {}
      # Example:
      # ridestatus-ansible:
      #   ansible_host: 10.15.140.100

    edge_nodes:
      hosts: {}
      # Example:
      # Goliath:
      #   ansible_host: 10.15.140.17
      #   ride_nic_ip: 192.168.1.254
      #   plc_ip: 192.168.1.2
      #   plc_protocol: enip
EOF
  chown "${RS_USER}:${RS_USER}" "${INVENTORY_DIR}/hosts.yml"
  ok "Starter inventory written to ${INVENTORY_DIR}/hosts.yml"
else
  info "Inventory already exists — leaving intact"
fi

# =============================================================================
# 7. Systemd timer — health-check playbook every 5 minutes
# =============================================================================
header "Systemd Health-Check Timer"

cat > /etc/systemd/system/ridestatus-healthcheck.service << EOF
[Unit]
Description=RideStatus Ansible Health Check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${RS_USER}
WorkingDirectory=${DEPLOY_DIR}
ExecStart=/usr/bin/ansible-playbook ansible/playbooks/healthcheck.yml \\
  -i ${INVENTORY_DIR}/hosts.yml
StandardOutput=append:${LOG_DIR}/healthcheck.log
StandardError=append:${LOG_DIR}/healthcheck.log
EOF

cat > /etc/systemd/system/ridestatus-healthcheck.timer << 'EOF'
[Unit]
Description=RideStatus Ansible Health Check Timer
After=network-online.target

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable ridestatus-healthcheck.timer
systemctl start  ridestatus-healthcheck.timer

ok "Health-check timer enabled (runs every 5 minutes)"

# =============================================================================
# 8. Ansible vault password file placeholder
# Used to encrypt sensitive vars (API keys, DB passwords) in group_vars.
# Tech sets this after bootstrap — do not generate automatically.
# =============================================================================
if [[ ! -f "${RS_HOME}/.vault_pass" ]]; then
  echo '# Replace this line with your vault password, then: chmod 600 ~/.vault_pass' \
    > "${RS_HOME}/.vault_pass"
  chmod 600 "${RS_HOME}/.vault_pass"
  chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.vault_pass"
  warn "Vault password file created at ${RS_HOME}/.vault_pass — set a real password before using ansible-vault"
fi

# =============================================================================
# Done — print public key for server.sh
# =============================================================================
header "Ansible Bootstrap Complete"

ANSIBLE_PUBKEY_CONTENT=$(cat "${ANSIBLE_KEY}.pub")

ok "ridestatus-deploy cloned: ${DEPLOY_DIR}"
ok "Inventory:              ${INVENTORY_DIR}/hosts.yml"
ok "Ansible log:            ${LOG_DIR}/ansible.log"
ok "Health-check timer:     active (every 5 min)"

echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${YELLOW}║           RECORD THIS — needed for server.sh                ║${RESET}"
echo -e "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${YELLOW}║ Ansible public key:                                          ║${RESET}"
echo -e "${BOLD}${YELLOW}║${RESET}"
echo    "   ${ANSIBLE_PUBKEY_CONTENT}"
echo -e "${BOLD}${YELLOW}║${RESET}"
echo -e "${BOLD}${YELLOW}║ This key is stored at: ${ANSIBLE_KEY}.pub${RESET}"
echo -e "${BOLD}${YELLOW}║ It will be passed to server.sh as ANSIBLE_PUBKEY            ║${RESET}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Next: run bootstrap/server.sh on the RideStatus Server VM"
info "      (provide the Ansible public key above when prompted)"
