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
#   2.  Configures chrony (stratum 2, internet pool — independent of edge nodes)
#   3.  Installs Node.js 22 (via NodeSource)
#   4.  Installs PostgreSQL 16 (via PGDG apt repo)
#   5.  Creates ridestatus DB user and database
#   6.  Ensures the 'ridestatus' OS user exists with correct home/permissions
#   7.  Acquires the Ansible public key (auto via env var from deploy.sh,
#       or prompts for key server URL, or allows manual paste as fallback)
#   8.  Stores the Ansible public key at ~/.ssh/ansible_ridestatus.pub and
#       adds it to authorized_keys so Ansible can manage this VM
#   9.  Interactively collects park config and writes /home/ridestatus/.env
#  10.  Clones ridestatus-server, installs npm deps, runs DB migrations
#  11.  Installs PM2, registers ridestatus-server, enables PM2 startup
#  12.  Configures UFW firewall rules
#  13.  Prints a deployment summary
#
# Key handoff modes (in priority order):
#   A) ANSIBLE_PUBKEY env var  — set by deploy.sh when both VMs are on the
#      same Proxmox host. Fully automatic, no tech interaction needed.
#   B) ANSIBLE_KEY_URL env var — set by deploy.sh when Ansible VM is on a
#      different host. Script fetches key from URL automatically.
#   C) Interactive prompt       — script asks for the key server URL.
#      Tech copies it from the ansible.sh terminal output.
#   D) Manual paste fallback    — if URL unreachable, tech pastes key directly.
#
# Usage (called by deploy.sh via SSH, or manually):
#   curl -fsSL https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap/server.sh | sudo bash
#   # Or with env var from deploy.sh:
#   ANSIBLE_PUBKEY="ssh-ed25519 AAAA..." sudo bash server.sh
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
  curl \
  git \
  ca-certificates \
  gnupg \
  lsb-release \
  ufw \
  jq \
  chrony \
  build-essential \
  python3

ok "Packages installed"

# =============================================================================
# 2. Chrony — stratum 2 from internet, independent of edge nodes
# Edge nodes will sync FROM this VM (server.sh does not configure that —
# that is handled by edge-init.sh which points edge chrony at this VM's
# dept-NIC IP). This VM just needs accurate time itself.
# =============================================================================
header "Configuring NTP (chrony)"

cat > /etc/chrony/chrony.conf << 'EOF'
# RideStatus Aggregation Server — chrony config
# Syncs from internet NTP pool (stratum 2).
# Edge nodes on the dept network sync from this VM (stratum 3).

pool pool.ntp.org iburst minpoll 6 maxpoll 10

# Allow edge nodes on the RideStatus dept network to sync from this VM.
# The subnet here should match the DEPT_NIC subnet configured during deploy.
# Default covers the reference park range; adjust if needed.
allow 10.0.0.0/8

# Serve time even if not synced (edge nodes may boot before we have sync)
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
chronyc tracking | grep 'Leap status' || warn "chrony not yet synced — may need internet route"

ok "chrony configured (stratum 2, NTP server for edge nodes)"

# =============================================================================
# 3. Node.js 22
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
# 4. PostgreSQL 16
# =============================================================================
header "Installing PostgreSQL 16"

if command -v psql &>/dev/null && psql --version | grep -q ' 16\.'; then
  info "PostgreSQL 16 already installed"
else
  info "Adding PGDG apt repository..."
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
# 5. ridestatus OS user
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
# 6. Ansible public key acquisition
#
# Priority:
#   A) ANSIBLE_PUBKEY env var (set by deploy.sh — same-host deployment)
#   B) ANSIBLE_KEY_URL env var (set by deploy.sh — cross-host deployment)
#   C) Interactive: prompt for key server URL, then fetch
#   D) Manual paste fallback (if fetch fails or times out)
# =============================================================================
header "Ansible Public Key"

ANSIBLE_PUBKEY_CONTENT=""

# Mode A — passed directly by deploy.sh
if [[ -n "${ANSIBLE_PUBKEY:-}" ]]; then
  ANSIBLE_PUBKEY_CONTENT="$ANSIBLE_PUBKEY"
  ok "Ansible public key received from deploy.sh (same-host mode)"

# Mode B — URL passed by deploy.sh (cross-host, ansible VM already bootstrapped)
elif [[ -n "${ANSIBLE_KEY_URL:-}" ]]; then
  info "Fetching Ansible public key from ${ANSIBLE_KEY_URL}..."
  ANSIBLE_PUBKEY_CONTENT=$(curl -fsSL --max-time 15 "$ANSIBLE_KEY_URL" 2>/dev/null || true)
  if [[ -n "$ANSIBLE_PUBKEY_CONTENT" ]]; then
    ok "Ansible public key fetched from URL"
  else
    warn "Could not fetch from ANSIBLE_KEY_URL — falling back to interactive prompt"
  fi
fi

# Mode C / D — interactive
if [[ -z "$ANSIBLE_PUBKEY_CONTENT" ]]; then
  echo ""
  echo -e "${BOLD}${YELLOW}Ansible public key needed${RESET}"
  echo "  The Ansible Controller VM printed a key server URL when ansible.sh ran."
  echo "  Example: http://10.15.140.100:${KEY_SERVER_PORT}/ansible_ridestatus.pub"
  echo ""
  echo "  Option 1 — Paste the key server URL (recommended):"
  read -rp "$(echo -e "${BOLD}  Key server URL (or press Enter to paste key manually): ${RESET}")" key_url

  if [[ -n "$key_url" ]]; then
    info "Fetching Ansible public key from ${key_url}..."
    ANSIBLE_PUBKEY_CONTENT=$(curl -fsSL --max-time 15 "$key_url" 2>/dev/null || true)
    if [[ -n "$ANSIBLE_PUBKEY_CONTENT" ]]; then
      ok "Ansible public key fetched"
    else
      warn "Could not reach key server. Falling back to manual paste."
    fi
  fi

  # Mode D — manual paste
  if [[ -z "$ANSIBLE_PUBKEY_CONTENT" ]]; then
    echo ""
    echo -e "${BOLD}  Paste the Ansible public key below (single line, starts with 'ssh-ed25519'):${RESET}"
    while true; do
      read -rp "  Public key: " ANSIBLE_PUBKEY_CONTENT
      if echo "$ANSIBLE_PUBKEY_CONTENT" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2) '; then
        break
      fi
      warn "  Does not look like a valid public key — try again."
    done
  fi
fi

# Validate final key
echo "$ANSIBLE_PUBKEY_CONTENT" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2) ' \
  || die "Ansible public key is invalid or empty"

# Store the key
echo "$ANSIBLE_PUBKEY_CONTENT" > "$ANSIBLE_PUBKEY_FILE"
chmod 644 "$ANSIBLE_PUBKEY_FILE"
chown "${RS_USER}:${RS_USER}" "$ANSIBLE_PUBKEY_FILE"

# Add to authorized_keys so Ansible can SSH in as ridestatus
AUTH_KEYS="${RS_HOME}/.ssh/authorized_keys"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "${RS_USER}:${RS_USER}" "$AUTH_KEYS"

if grep -qF "$ANSIBLE_PUBKEY_CONTENT" "$AUTH_KEYS" 2>/dev/null; then
  info "Ansible public key already in authorized_keys"
else
  echo "$ANSIBLE_PUBKEY_CONTENT" >> "$AUTH_KEYS"
  ok "Ansible public key added to ${AUTH_KEYS}"
fi

ok "Ansible key stored: ${ANSIBLE_PUBKEY_FILE}"

# =============================================================================
# 7. Park configuration — interactive, writes .env
# Only prompts if .env doesn't already exist (idempotent re-runs skip this).
# =============================================================================
header "Park Configuration"

if [[ -f "$ENV_FILE" ]]; then
  info ".env already exists at ${ENV_FILE} — leaving intact"
  info "To reconfigure: rm ${ENV_FILE} and re-run"
  source "$ENV_FILE"
else
  info "Collecting park configuration — this writes ${ENV_FILE}"
  echo ""

  prompt_required PARK_NAME     "Park name (e.g. Six Flags Great America)"
  prompt_default  PARK_TIMEZONE "Timezone" "America/Chicago"

  echo ""
  info "PostgreSQL credentials (database will be created with these)"
  prompt_default  POSTGRES_DB   "PostgreSQL database name" "ridestatus"
  prompt_default  POSTGRES_USER "PostgreSQL username"      "ridestatus"

  # Generate a random password if tech just hits Enter
  local_pg_pass=$(tr -dc 'A-Za-z0-9_' < /dev/urandom | head -c 32 || true)
  prompt_default  POSTGRES_PASS "PostgreSQL password (Enter to generate)" "$local_pg_pass"

  echo ""
  info "API settings"
  local_api_key=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 || true)
  prompt_default  API_PORT "API port" "3100"
  prompt_default  API_KEY  "API key (Enter to generate)" "$local_api_key"

  # Bootstrap token — 8 chars max, shown in admin UI, edge nodes use during enrollment
  local_bt=$(tr -dc 'A-Z0-9' < /dev/urandom | head -c 8 || true)
  prompt_default  SERVER_BOOTSTRAP_TOKEN "Edge enrollment token (max 8 chars)" "$local_bt"
  SERVER_BOOTSTRAP_TOKEN="${SERVER_BOOTSTRAP_TOKEN:0:8}"

  echo ""
  info "NIC interface names (check with: ip -o link show)"
  prompt_default  DEPT_NIC_INTERFACE     "Dept/RideStatus network NIC" "ens18"
  prompt_default  EXTERNAL_NIC_INTERFACE "Corporate/external NIC"      "ens19"

  echo ""
  info "Optional: weather and alerting (leave blank to configure later)"
  prompt_default  WEATHER_API_KEY ""  ""
  prompt_default  WEATHER_ZIP     "Weather ZIP code" ""
  prompt_default  ALERT_EMAIL     "Alert email address" ""

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

DEPT_NIC_INTERFACE=${DEPT_NIC_INTERFACE}
EXTERNAL_NIC_INTERFACE=${EXTERNAL_NIC_INTERFACE}

ANSIBLE_PUBKEY_PATH=${ANSIBLE_PUBKEY_FILE}

WEATHER_API_KEY=${WEATHER_API_KEY:-}
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

  # Source it so the rest of the script can use the vars
  source "$ENV_FILE"
fi

# =============================================================================
# 8. PostgreSQL — create user and database
# =============================================================================
header "Configuring PostgreSQL"

# Create user (ignore error if already exists)
sudo -u postgres psql -tc \
  "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" \
  | grep -q 1 || \
  sudo -u postgres psql -c \
    "CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASS}';"

# Create database (ignore error if already exists)
sudo -u postgres psql -tc \
  "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" \
  | grep -q 1 || \
  sudo -u postgres psql -c \
    "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};"

ok "PostgreSQL user '${POSTGRES_USER}' and database '${POSTGRES_DB}' ready"

# =============================================================================
# 9. Clone ridestatus-server, install deps, run migrations
# =============================================================================
header "Deploying ridestatus-server"

if [[ -d "${APP_DIR}/.git" ]]; then
  info "Repo already cloned — pulling latest"
  sudo -u "$RS_USER" git -C "$APP_DIR" pull --ff-only
else
  sudo -u "$RS_USER" git clone "$APP_REPO" "$APP_DIR"
  ok "Repo cloned to ${APP_DIR}"
fi

# Install npm dependencies
info "Installing npm dependencies..."
sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && npm ci --omit=dev --silent"
ok "npm dependencies installed"

# Copy .env into app directory (app reads from cwd/.env)
ln -sf "$ENV_FILE" "${APP_DIR}/.env"
chown -h "${RS_USER}:${RS_USER}" "${APP_DIR}/.env"

# Create logs directory if not present
mkdir -p "$LOG_DIR"
chown "${RS_USER}:${RS_USER}" "$LOG_DIR"

# Run database migrations
info "Running database migrations..."
sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && node db/migrate.js" \
  && ok "Migrations complete" \
  || die "Database migration failed — check ${LOG_DIR}/server-err.log"

# =============================================================================
# 10. PM2 — install, start app, configure startup
# =============================================================================
header "Configuring PM2"

# Install PM2 globally if not present or outdated
if ! command -v pm2 &>/dev/null; then
  npm install -g pm2 --silent
  ok "PM2 installed"
else
  info "PM2 already installed ($(pm2 --version))"
fi

# Start or reload the app
if sudo -u "$RS_USER" pm2 describe ridestatus-server &>/dev/null; then
  info "PM2 process exists — reloading"
  sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && pm2 reload ecosystem.config.js"
else
  sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && pm2 start ecosystem.config.js"
  ok "PM2 process started"
fi

# Save process list and configure startup
sudo -u "$RS_USER" pm2 save

# Generate and install the systemd startup hook
pm2 startup systemd -u "$RS_USER" --hp "$RS_HOME" \
  | tail -n 1 | bash 2>/dev/null || true
systemctl enable "pm2-${RS_USER}" 2>/dev/null || true

ok "PM2 startup configured (ridestatus-server survives reboots)"

# =============================================================================
# 11. UFW firewall
# =============================================================================
header "Configuring Firewall"

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh                              comment "Admin SSH"
ufw allow "${API_PORT:-3100}/tcp"         comment "RideStatus API (edge nodes + Ansible)"
ufw allow 3000/tcp                         comment "RideStatus board UI"
ufw allow 123/udp                          comment "NTP — edge nodes sync from this VM"
# PostgreSQL is localhost-only by default (no ufw rule needed)
# To allow Ansible direct DB access from the Ansible VM, add:
#   ufw allow from <ansible-vm-ip> to any port 5432
ufw --force enable
ok "Firewall configured"

# =============================================================================
# Done
# =============================================================================
header "Server Bootstrap Complete"

ok "Node.js:      $(node --version)"
ok "PostgreSQL:   $(psql --version | awk '{print $3}')"
ok "PM2:          $(pm2 --version)"
ok "App:          ${APP_DIR}"
ok "Config:       ${ENV_FILE}"
ok "Ansible key:  ${ANSIBLE_PUBKEY_FILE}"
ok "Logs:         ${LOG_DIR}"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║              RideStatus Server Ready                        ║${RESET}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}║  API:              http://$(hostname -I | awk '{print $1}'):${API_PORT:-3100}${RESET}"
echo -e "${BOLD}${GREEN}║  Board UI:         http://$(hostname -I | awk '{print $1}'):3000${RESET}"
echo -e "${BOLD}${GREEN}║  Enrollment token: ${SERVER_BOOTSTRAP_TOKEN}${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}║  Next: run bootstrap/edge-init.sh on each ride edge node    ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "PM2 status: sudo -u ridestatus pm2 status"
info "App logs:   sudo -u ridestatus pm2 logs ridestatus-server"
