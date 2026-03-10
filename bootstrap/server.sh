#!/usr/bin/env bash
# =============================================================================
# RideStatus — Aggregation Server Bootstrap
# https://github.com/RideStatus/ridestatus-deploy
#
# Run inside the RideStatus Server VM after creation by deploy.sh.
# Can also be run manually to re-bootstrap or repair an existing install.
#
# What this script does:
#   1.  Installs system packages
#   2.  Installs Node.js 22 (via NodeSource)
#   3.  Installs PostgreSQL 16 (via PGDG apt repo)
#   4.  Ensures the 'ridestatus' OS user exists with correct home/permissions
#   5.  Acquires the Ansible public key:
#         a) Curls ANSIBLE_KEY_URL if set by deploy.sh (same-host mode) — no
#            quoting issues, server.sh fetches directly from the key server
#         b) Prompts for key server URL if not set (cross-host mode)
#         c) Allows manual paste as fallback
#   6.  Stores the Ansible public key and adds it to authorized_keys
#   7.  Interactively collects park config and writes /home/ridestatus/.env
#       ANSIBLE_VM_HOST and NIC interface names are pre-populated when
#       deploy.sh passes RS_DEPT_NIC_HINT / RS_CORP_NIC_HINT / ANSIBLE_VM_HOST
#   8.  Configures chrony (stratum 2, serves dept subnet)
#   9.  Creates ridestatus DB user and database
#  10.  Clones ridestatus-server, installs npm deps, runs DB migrations
#  11.  Installs PM2, registers ridestatus-server, enables PM2 startup
#  12.  Configures UFW firewall
#  13.  Prints deployment summary with management UI URL
#
# Usage (called by deploy.sh via SSH, or manually):
#   curl -fsSL https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap/server.sh | sudo bash
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[server.sh]${RESET} $*"; }
ok()     { echo -e "${GREEN}[server.sh]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[server.sh]${RESET} $*"; }
die()    { echo -e "${RED}[server.sh] ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

prompt_default() {
  local -n _var=$1; local msg=$2 def=$3
  read -rp "$(echo -e "${BOLD}${msg}${RESET} [${def}]: ")" _var
  _var=${_var:-$def}
}

prompt_required() {
  local -n _var=$1; local msg=$2
  while true; do
    read -rp "$(echo -e "${BOLD}${msg}${RESET}: ")" _var
    [[ -n "$_var" ]] && break
    warn "This field is required."
  done
}

dept_nic_subnet() {
  local iface=$1
  local ip prefix
  read -r ip prefix < <(
    ip -o -4 addr show dev "$iface" 2>/dev/null \
    | awk '{split($4,a,"/"); print a[1], a[2]}' | head -1
  ) || true
  [[ -z "$ip" || -z "$prefix" ]] && return 0
  IFS=. read -r a b c d <<< "$ip"
  local ip_int=$(( (a<<24) | (b<<16) | (c<<8) | d ))
  local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
  local net_int=$(( ip_int & mask ))
  printf "%d.%d.%d.%d/%d\n" \
    $(( (net_int>>24) & 0xFF )) $(( (net_int>>16) & 0xFF )) \
    $(( (net_int>>8)  & 0xFF )) $((  net_int      & 0xFF )) \
    "$prefix"
}

# Resolve a NIC hint from deploy.sh (e.g. "net0") to the actual kernel
# interface name. For bridge NICs, Proxmox assigns ens18, ens19, etc. in
# attachment order on Ubuntu 24.04 with virtio NICs. We map net0->ens18,
# net1->ens19, etc. and fall back to enp0sN or the provided default.
resolve_nic_hint() {
  local hint=$1 default=$2
  [[ -z "$hint" ]] && { echo "$default"; return; }
  local idx="${hint#net}"
  if [[ "$idx" =~ ^[0-9]+$ ]]; then
    local candidate="ens$(( 18 + idx ))"
    ip link show "$candidate" &>/dev/null 2>&1 && { echo "$candidate"; return; }
    candidate="enp0s$(( idx + 1 ))"
    ip link show "$candidate" &>/dev/null 2>&1 && { echo "$candidate"; return; }
  fi
  echo "$default"
}

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo bash server.sh)"

RS_USER="ridestatus"
RS_HOME="/home/${RS_USER}"
APP_DIR="${RS_HOME}/ridestatus-server"
LOG_DIR="${RS_HOME}/logs"
ENV_FILE="${RS_HOME}/.env"
ANSIBLE_PUBKEY_FILE="${RS_HOME}/.ssh/ansible_ridestatus.pub"
APP_REPO="https://github.com/RideStatus/ridestatus-server.git"
KEY_SERVER_PORT=9876

# =============================================================================
# 1. System packages
# =============================================================================
header "Installing System Packages"

apt-get update -qq
apt-get install -y --no-install-recommends \
  curl git ca-certificates gnupg lsb-release \
  ufw jq chrony build-essential python3 openssh-client

ok "Packages installed"

# =============================================================================
# 2. Node.js 22
# =============================================================================
header "Installing Node.js 22"

if node --version 2>/dev/null | grep -q '^v22\.'; then
  info "Node.js 22 already installed ($(node --version))"
else
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y --no-install-recommends nodejs
  ok "Node.js installed: $(node --version)"
fi

# =============================================================================
# 3. PostgreSQL 16
# =============================================================================
header "Installing PostgreSQL 16"

if command -v psql &>/dev/null && psql --version | grep -q ' 16\.'; then
  info "PostgreSQL 16 already installed"
else
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
  echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y --no-install-recommends postgresql-16
  ok "PostgreSQL 16 installed"
fi

systemctl enable postgresql
systemctl start postgresql
ok "PostgreSQL running"

# =============================================================================
# 4. ridestatus OS user
# =============================================================================
header "Ensuring ridestatus User"

if ! id "$RS_USER" &>/dev/null; then
  useradd -m -s /bin/bash -d "$RS_HOME" "$RS_USER"
  ok "User ${RS_USER} created"
else
  info "User ${RS_USER} already exists"
fi

mkdir -p "${RS_HOME}/.ssh" "$LOG_DIR"
chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"
ok "Home directory ready: ${RS_HOME}"

# =============================================================================
# 5 & 6. Ansible public key
#
# deploy.sh passes ANSIBLE_KEY_URL pointing to ansible.sh's one-shot key
# server. server.sh curls it directly — no shell quoting issues. Falls back
# to prompting for a URL or manual paste if not set (cross-host mode or retry).
# =============================================================================
header "Ansible Public Key"

ANSIBLE_PUBKEY_CONTENT=""

if [[ -n "${ANSIBLE_KEY_URL:-}" ]]; then
  info "Fetching Ansible public key from ${ANSIBLE_KEY_URL} (provided by deploy.sh)..."
  ANSIBLE_PUBKEY_CONTENT=$(curl -fsSL --max-time 30 "$ANSIBLE_KEY_URL" 2>/dev/null || true)
  if [[ -n "$ANSIBLE_PUBKEY_CONTENT" ]]; then
    ok "Ansible public key fetched successfully"
  else
    warn "Could not fetch from ANSIBLE_KEY_URL — key server may have timed out. Falling back."
  fi
fi

if [[ -z "$ANSIBLE_PUBKEY_CONTENT" ]]; then
  echo ""
  echo -e "${BOLD}${YELLOW}Ansible public key needed${RESET}"
  echo "  The Ansible VM printed a key server URL when ansible.sh ran."
  echo "  Example: http://10.15.140.100:${KEY_SERVER_PORT}/ansible_ridestatus.pub"
  echo ""
  read -rp "$(echo -e "${BOLD}  Key server URL (or press Enter to paste manually): ${RESET}")" key_url

  if [[ -n "$key_url" ]]; then
    ANSIBLE_PUBKEY_CONTENT=$(curl -fsSL --max-time 15 "$key_url" 2>/dev/null || true)
    [[ -n "$ANSIBLE_PUBKEY_CONTENT" ]] && ok "Ansible public key fetched" \
      || warn "Could not reach key server. Falling back to manual paste."
  fi

  if [[ -z "$ANSIBLE_PUBKEY_CONTENT" ]]; then
    echo ""
    echo -e "${BOLD}  Paste the Ansible public key (starts with 'ssh-ed25519'):${RESET}"
    while true; do
      read -rp "  Public key: " ANSIBLE_PUBKEY_CONTENT
      echo "$ANSIBLE_PUBKEY_CONTENT" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2) ' && break
      warn "  Does not look like a valid public key — try again."
    done
  fi
fi

echo "$ANSIBLE_PUBKEY_CONTENT" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2) ' \
  || die "Ansible public key is invalid or empty"

echo "$ANSIBLE_PUBKEY_CONTENT" > "$ANSIBLE_PUBKEY_FILE"
chmod 644 "$ANSIBLE_PUBKEY_FILE"
chown "${RS_USER}:${RS_USER}" "$ANSIBLE_PUBKEY_FILE"

AUTH_KEYS="${RS_HOME}/.ssh/authorized_keys"
touch "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"; chown "${RS_USER}:${RS_USER}" "$AUTH_KEYS"

if grep -qF "$ANSIBLE_PUBKEY_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
  info "Ansible public key already in authorized_keys"
else
  echo "$ANSIBLE_PUBKEY_CONTENT" >> "$AUTH_KEYS"
  ok "Ansible public key added to ${AUTH_KEYS}"
fi

# =============================================================================
# 7. Park configuration — interactive, writes .env
# =============================================================================
header "Park Configuration"

if [[ -f "$ENV_FILE" ]]; then
  info ".env already exists — leaving intact (rm ${ENV_FILE} to reconfigure)"
  source "$ENV_FILE"
else
  info "Collecting park configuration — writes ${ENV_FILE}"
  echo ""

  prompt_required PARK_NAME     "Park name (e.g. Six Flags Great America)"
  prompt_default  PARK_TIMEZONE "Timezone" "America/Chicago"

  echo ""
  info "PostgreSQL credentials"
  prompt_default POSTGRES_DB   "Database name" "ridestatus"
  prompt_default POSTGRES_USER "Username"      "ridestatus"
  local_pg_pass=$(tr -dc 'A-Za-z0-9_' < /dev/urandom | head -c 32 || true)
  prompt_default POSTGRES_PASS "Password (Enter to generate)" "$local_pg_pass"

  echo ""
  info "API settings"
  local_api_key=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
  prompt_default API_PORT "API port" "3100"
  prompt_default API_KEY  "API key (Enter to generate)" "$local_api_key"

  local_bt=$(tr -dc 'A-Z0-9' < /dev/urandom | head -c 8 || true)
  prompt_default SERVER_BOOTSTRAP_TOKEN "Edge enrollment token (max 8 chars)" "$local_bt"
  SERVER_BOOTSTRAP_TOKEN="${SERVER_BOOTSTRAP_TOKEN:0:8}"

  echo ""
  info "NIC interfaces — shown below for reference:"
  ip -o link show | awk -F': ' '{print "  "$2}' | grep -v lo
  echo ""

  # Pre-populate NIC defaults from role hints passed by deploy.sh
  DEPT_NIC_DEFAULT=$(resolve_nic_hint "${RS_DEPT_NIC_HINT:-}" "ens18")
  CORP_NIC_DEFAULT=$(resolve_nic_hint "${RS_CORP_NIC_HINT:-}" "ens19")

  prompt_default DEPT_NIC_INTERFACE     "Department / RideStatus network NIC (chrony, management UI, edge traffic)" "$DEPT_NIC_DEFAULT"
  prompt_default EXTERNAL_NIC_INTERFACE "Corporate / external NIC (internet, corporate VLAN)"                       "$CORP_NIC_DEFAULT"

  echo ""
  info "Ansible VM — the management UI uses this to deploy edge nodes"
  echo "  Leave blank if you do not have an Ansible VM yet."
  echo "  You can set ANSIBLE_VM_HOST in ${ENV_FILE} later."
  ANSIBLE_VM_HOST_DEFAULT="${ANSIBLE_VM_HOST:-}"
  prompt_default ANSIBLE_VM_HOST "Ansible VM dept-NIC IP" "$ANSIBLE_VM_HOST_DEFAULT"

  echo ""
  info "Optional: weather and alerting (leave blank to configure later)"
  prompt_default WEATHER_ZIP  "Weather ZIP code"    ""
  prompt_default ALERT_EMAIL  "Alert email address" ""

  DEPT_NIC_IP_NOW=$(ip -4 addr show dev "${DEPT_NIC_INTERFACE}" 2>/dev/null \
    | awk '/inet /{split($2,a,"/"); print a[1]}' | head -1 || true)

  cat > "$ENV_FILE" << EOF
# =============================================================================
# RideStatus Server — Environment
# Generated by server.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

PARK_NAME=${PARK_NAME}
PARK_TIMEZONE=${PARK_TIMEZONE}

POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASS=${POSTGRES_PASS}

API_PORT=${API_PORT}
API_KEY=${API_KEY}

SERVER_BOOTSTRAP_TOKEN=${SERVER_BOOTSTRAP_TOKEN}

# Department / RideStatus network — chrony NTP, management UI, edge node traffic
DEPT_NIC_INTERFACE=${DEPT_NIC_INTERFACE}
DEPT_NIC_IP=${DEPT_NIC_IP_NOW}

# Corporate / external network — internet access, corporate VLAN
EXTERNAL_NIC_INTERFACE=${EXTERNAL_NIC_INTERFACE}

ANSIBLE_PUBKEY_PATH=${ANSIBLE_PUBKEY_FILE}

# Ansible VM — used by the management UI to deploy edge nodes remotely
# Set to the Ansible VM's dept-NIC IP address after running ansible.sh there.
ANSIBLE_VM_HOST=${ANSIBLE_VM_HOST:-}
ANSIBLE_VM_USER=ridestatus
ANSIBLE_VM_KEY=${ANSIBLE_PUBKEY_FILE%%.pub}
ANSIBLE_INVENTORY_DIR=/home/ridestatus/inventory
ANSIBLE_DEPLOY_DIR=/home/ridestatus/ridestatus-deploy

WEATHER_ZIP=${WEATHER_ZIP:-}
WEATHER_POLL_INTERVAL_S=60

ALERT_EMAIL=${ALERT_EMAIL:-}
ALERT_SMS=
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=

OFFLINE_TIMEOUT_S=300
RTC_DRIFT_WARN_S=900

LOG_LEVEL=info
LOG_FILE=logs/server.log
EOF

  chmod 600 "$ENV_FILE"
  chown "${RS_USER}:${RS_USER}" "$ENV_FILE"
  ok ".env written to ${ENV_FILE}"
  source "$ENV_FILE"
fi

# =============================================================================
# 8. Chrony
# =============================================================================
header "Configuring NTP (chrony)"

DEPT_SUBNET=$(dept_nic_subnet "${DEPT_NIC_INTERFACE:-ens18}" || true)

if [[ -z "$DEPT_SUBNET" ]]; then
  warn "Could not determine subnet for ${DEPT_NIC_INTERFACE} — using 10.0.0.0/8 fallback"
  DEPT_SUBNET="10.0.0.0/8"
else
  ok "Dept NIC subnet: ${DEPT_SUBNET}"
fi

cat > /etc/chrony/chrony.conf << EOF
# RideStatus Aggregation Server — chrony config
# Generated by server.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
pool pool.ntp.org iburst minpoll 6 maxpoll 10
allow ${DEPT_SUBNET}
local stratum 3
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF

systemctl enable chrony
systemctl restart chrony

for i in $(seq 1 6); do
  chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal' && break
  sleep 5
done
chronyc tracking | grep 'Leap status' \
  || warn "chrony not yet synced — may need internet route on ${EXTERNAL_NIC_INTERFACE:-ens19}"

ok "chrony configured (allow ${DEPT_SUBNET})"

# =============================================================================
# 9. PostgreSQL — create user and database
# =============================================================================
header "Configuring PostgreSQL"

sudo -u postgres psql -tc \
  "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" \
  | grep -q 1 || \
  sudo -u postgres psql -c \
    "CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASS}';"

sudo -u postgres psql -tc \
  "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" \
  | grep -q 1 || \
  sudo -u postgres psql -c \
    "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};"

ok "PostgreSQL user '${POSTGRES_USER}' and database '${POSTGRES_DB}' ready"

# =============================================================================
# 10. Clone ridestatus-server, install deps, run migrations
# =============================================================================
header "Deploying ridestatus-server"

if [[ -d "${APP_DIR}/.git" ]]; then
  info "Repo already cloned — pulling latest"
  sudo -u "$RS_USER" git -C "$APP_DIR" pull --ff-only
else
  sudo -u "$RS_USER" git clone "$APP_REPO" "$APP_DIR"
  ok "Repo cloned to ${APP_DIR}"
fi

sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && npm ci --omit=dev --silent"
ok "npm dependencies installed"

ln -sf "$ENV_FILE" "${APP_DIR}/.env"
chown -h "${RS_USER}:${RS_USER}" "${APP_DIR}/.env"
mkdir -p "$LOG_DIR"
chown "${RS_USER}:${RS_USER}" "$LOG_DIR"

sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && node db/migrate.js" \
  && ok "Migrations complete" \
  || die "Migration failed — check ${LOG_DIR}/server-err.log"

# =============================================================================
# 11. PM2
# =============================================================================
header "Configuring PM2"

if ! command -v pm2 &>/dev/null; then
  npm install -g pm2 --silent
  ok "PM2 installed"
else
  info "PM2 already installed ($(pm2 --version))"
fi

if sudo -u "$RS_USER" pm2 describe rs-server &>/dev/null; then
  sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && pm2 reload ecosystem.config.js"
else
  sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && pm2 start ecosystem.config.js"
  ok "PM2 process started"
fi

sudo -u "$RS_USER" pm2 save
pm2 startup systemd -u "$RS_USER" --hp "$RS_HOME" | tail -n 1 | bash 2>/dev/null || true
systemctl enable "pm2-${RS_USER}" 2>/dev/null || true
ok "PM2 startup configured"

# =============================================================================
# 12. UFW firewall
# =============================================================================
header "Configuring Firewall"

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh                                           comment "Admin SSH"
ufw allow "${API_PORT:-3100}/tcp"                      comment "RideStatus API + UI"
ufw allow from "${DEPT_SUBNET}" to any port 123 proto udp \
                                                        comment "NTP — dept network only"
ufw --force enable

ok "Firewall configured"

# =============================================================================
# Done
# =============================================================================
header "Server Bootstrap Complete"

SERVER_IP=$(ip -4 addr show dev "${DEPT_NIC_INTERFACE:-ens18}" \
  | grep -o 'inet [0-9.]*' | awk '{print $2}' || echo "<server-ip>")

ok "Node.js:      $(node --version)"
ok "PostgreSQL:   $(psql --version | awk '{print $3}')"
ok "PM2:          $(pm2 --version)"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║              RideStatus Server Ready                         ║${RESET}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
printf  "${BOLD}${GREEN}║  Main board:   http://%-39s║${RESET}\n" "${SERVER_IP}:${API_PORT:-3100}/"
printf  "${BOLD}${GREEN}║  Management:   http://%-39s║${RESET}\n" "${SERVER_IP}:${API_PORT:-3100}/manage"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}║  Enrollment token: ${SERVER_BOOTSTRAP_TOKEN}$(printf '%*s' $((44 - ${#SERVER_BOOTSTRAP_TOKEN})) '')║${RESET}"
echo -e "${BOLD}${GREEN}║  Dept NTP subnet:  ${DEPT_SUBNET}$(printf '%*s' $((44 - ${#DEPT_SUBNET})) '')║${RESET}"
if [[ -n "${ANSIBLE_VM_HOST:-}" ]]; then
echo -e "${BOLD}${GREEN}║  Ansible VM:       ${ANSIBLE_VM_HOST}$(printf '%*s' $((44 - ${#ANSIBLE_VM_HOST})) '')║${RESET}"
else
echo -e "${BOLD}${YELLOW}║  Ansible VM:       not set — add ANSIBLE_VM_HOST to .env    ║${RESET}"
fi
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}║  Next steps:                                                 ║${RESET}"
echo -e "${BOLD}${GREEN}║  1. Run edge-init.sh on each edge node                       ║${RESET}"
echo -e "${BOLD}${GREEN}║  2. Open /manage to add rides and trigger deploys             ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "PM2 status: sudo -u ridestatus pm2 status"
info "App logs:   sudo -u ridestatus pm2 logs rs-server"
