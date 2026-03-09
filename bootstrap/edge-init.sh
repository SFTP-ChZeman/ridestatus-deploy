#!/usr/bin/env bash
# =============================================================================
# RideStatus — Ride Edge Node Bootstrap (edge-init.sh)
# https://github.com/RideStatus/ridestatus-deploy
#
# Run on a fresh Pi or VM to provision it as a RideStatus ride edge node.
# Can be re-run safely to repair or update an existing install.
#
# What this script does:
#   1.  Installs system packages
#   2.  Installs Node.js 22
#   3.  Installs Node-RED globally
#   4.  Ensures the 'ridestatus' OS user exists
#   5.  Interactively collects ride config and writes /home/ridestatus/.env
#   6.  Configures chrony — syncs from the RideStatus Server VM (stratum 3)
#       on the dept NIC; serves NTP to PLC/ride-network devices on the ride NIC
#       Ride NIC NTP subnet is calculated from the ride NIC's own IP/prefix.
#   7.  Creates SQLite data directory
#   8.  Clones ridestatus-ride, installs npm deps
#   9.  Installs PM2, starts rs-poller + rs-nodered, enables PM2 startup
#  10.  Configures UFW firewall
#       — NTP on ride NIC subnet only (PLCs sync from this node)
#       — Node-RED UI on ride NIC only (accessible from ride-side devices)
#       — Inbound from server VM only on dept NIC (Ansible SSH)
#  11.  Registers this node with the RideStatus Server via the bootstrap API
#  12.  Prints a deployment summary
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap/edge-init.sh | sudo bash
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[edge-init]${RESET} $*"; }
ok()     { echo -e "${GREEN}[edge-init]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[edge-init]${RESET} $*"; }
die()    { echo -e "${RED}[edge-init] ERROR:${RESET} $*" >&2; exit 1; }
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

# Derive network CIDR from a NIC's IP + prefix.
# e.g. 192.168.1.254/24 → 192.168.1.0/24
nic_subnet() {
  local iface=$1
  local ip prefix
  read -r ip prefix < <(
    ip -o -4 addr show dev "$iface" 2>/dev/null \
    | awk '{split($4,a,"/"); print a[1], a[2]}' | head -1
  ) || true
  [[ -z "$ip" || -z "$prefix" ]] && return 0
  IFS=. read -r a b c d <<< "$ip"
  local ip_int=$(( (a<<24)|(b<<16)|(c<<8)|d ))
  local mask=$(( 0xFFFFFFFF << (32-prefix) & 0xFFFFFFFF ))
  local net=$(( ip_int & mask ))
  printf "%d.%d.%d.%d/%d\n" \
    $(((net>>24)&0xFF)) $(((net>>16)&0xFF)) $(((net>>8)&0xFF)) $((net&0xFF)) "$prefix"
}

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo bash edge-init.sh)"

RS_USER="ridestatus"
RS_HOME="/home/${RS_USER}"
APP_DIR="${RS_HOME}/ridestatus-ride"
ENV_FILE="${RS_HOME}/.env"
DATA_DIR="${RS_HOME}/data"
LOG_DIR="/var/log/ridestatus"
APP_REPO="https://github.com/RideStatus/ridestatus-ride.git"

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
  sqlite3 \
  ufw \
  chrony \
  build-essential \
  python3 \
  jq

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
# 3. Node-RED
# =============================================================================
header "Installing Node-RED"

if command -v node-red &>/dev/null; then
  info "Node-RED already installed ($(node-red --version 2>/dev/null || echo unknown))"
else
  npm install -g --unsafe-perm node-red --silent
  ok "Node-RED installed"
fi

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

mkdir -p "${RS_HOME}/.ssh" "$DATA_DIR" "$LOG_DIR"
chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"
chown "${RS_USER}:${RS_USER}" "$LOG_DIR"

ok "Directories ready"

# =============================================================================
# 5. Ride configuration — interactive, writes .env
# Skipped on re-run if .env already exists.
# =============================================================================
header "Ride Configuration"

if [[ -f "$ENV_FILE" ]]; then
  info ".env already exists — leaving intact (rm ${ENV_FILE} to reconfigure)"
  source "$ENV_FILE"
else
  info "Collecting ride configuration — writes ${ENV_FILE}"
  echo ""

  prompt_required RIDE_NAME "Ride name (e.g. Goliath)"

  echo ""
  info "PLC connection"
  pick_protocol=0
  echo -e "${BOLD}PLC protocol:${RESET}"
  echo "  1) enip   — EtherNet/IP (ControlLogix, CompactLogix)"
  echo "  2) pccc   — PCCC (older Allen Bradley: SLC, PLC-5)"
  echo "  3) netdde — NetDDE (legacy, requires Windows bridge)"
  while true; do
    read -rp "Choice [1]: " pick_protocol
    pick_protocol=${pick_protocol:-1}
    case "$pick_protocol" in
      1) PLC_PROTOCOL=enip;   break ;;
      2) PLC_PROTOCOL=pccc;   break ;;
      3) PLC_PROTOCOL=netdde; break ;;
      *) warn "Enter 1, 2, or 3." ;;
    esac
  done

  prompt_required PLC_IP "PLC IP address"

  PLC_SLOT=0
  NETDDE_HOST=""
  NETDDE_SHARE=""

  if [[ "$PLC_PROTOCOL" == "enip" ]]; then
    prompt_default PLC_SLOT "ControlLogix backplane slot" "0"
  elif [[ "$PLC_PROTOCOL" == "netdde" ]]; then
    prompt_required NETDDE_HOST  "NetDDE host (Windows bridge IP or hostname)"
    prompt_required NETDDE_SHARE "NetDDE share name"
  fi

  echo ""
  info "PLC tag names — press Enter to accept defaults"
  prompt_default TAG_MODE          "Run/stop mode tag"        "ProgramMode"
  prompt_default TAG_FAULT         "Fault code tag"           "FaultCode"
  prompt_default TAG_FAULT_MESSAGE "Fault message tag"        "FaultMessage"
  prompt_default TAG_FAULT_TS      "Fault timestamp tag"      "FaultTimestamp"
  prompt_default TAG_CYCLE_COUNT   "Total cycle count tag"    "TotalCycles"
  prompt_default TAG_CYCLE_TIME    "Last cycle time tag"      "LastCycleTime"
  prompt_default TAG_STATUS_MSG    "Status message tag"       "StatusMessage"
  prompt_default TAG_RTC           "PLC system time tag"      "SystemTime"

  echo ""
  info "NIC interfaces — shown below for reference:"
  ip -o link show | awk -F': ' '{print "  "$2}' | grep -v lo
  echo ""
  prompt_default RIDESTATUS_NIC_INTERFACE "Dept/RideStatus network NIC" "eth1"
  prompt_default RIDE_NIC_INTERFACE       "Ride/PLC network NIC"        "eth0"

  echo ""
  info "Aggregation server"
  prompt_required SERVER_HOST "Server VM IP (dept NIC)"
  prompt_default  SERVER_PORT "Server API port" "3100"
  prompt_required SERVER_API_KEY "Server API key"
  prompt_required SERVER_BOOTSTRAP_TOKEN "Server enrollment token (8 chars, shown on server)"

  echo ""
  info "Timing (press Enter for defaults)"
  prompt_default POLL_INTERVAL_MS  "PLC poll interval (ms)"         "1000"
  prompt_default PUSH_INTERVAL_S   "Push interval to server (s)"    "3"
  prompt_default OFFLINE_TIMEOUT_S "Offline timeout (s)"            "300"
  prompt_default PUSH_MAX_QUEUE    "Max push queue (offline buffer)" "20"

  cat > "$ENV_FILE" << EOF
# =============================================================================
# RideStatus Edge Node — Environment
# Generated by edge-init.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

# Ride identity
RIDE_NAME=${RIDE_NAME}

# PLC connection
PLC_PROTOCOL=${PLC_PROTOCOL}
PLC_IP=${PLC_IP}
PLC_SLOT=${PLC_SLOT}

# NetDDE (only used if PLC_PROTOCOL=netdde)
NETDDE_HOST=${NETDDE_HOST}
NETDDE_SHARE=${NETDDE_SHARE}

# PLC tag names
TAG_MODE=${TAG_MODE}
TAG_FAULT=${TAG_FAULT}
TAG_FAULT_MESSAGE=${TAG_FAULT_MESSAGE}
TAG_FAULT_TS=${TAG_FAULT_TS}
TAG_CYCLE_COUNT=${TAG_CYCLE_COUNT}
TAG_CYCLE_TIME=${TAG_CYCLE_TIME}
TAG_STATUS_MESSAGE=${TAG_STATUS_MSG}
TAG_RTC=${TAG_RTC}

# Network interfaces
RIDESTATUS_NIC_INTERFACE=${RIDESTATUS_NIC_INTERFACE}
RIDE_NIC_INTERFACE=${RIDE_NIC_INTERFACE}

# Aggregation server
SERVER_HOST=${SERVER_HOST}
SERVER_PORT=${SERVER_PORT}
SERVER_API_KEY=${SERVER_API_KEY}

# Timing
POLL_INTERVAL_MS=${POLL_INTERVAL_MS}
PUSH_INTERVAL_S=${PUSH_INTERVAL_S}
OFFLINE_TIMEOUT_S=${OFFLINE_TIMEOUT_S}
PUSH_MAX_QUEUE=${PUSH_MAX_QUEUE}

# SQLite
SQLITE_PATH=${DATA_DIR}/ride.db

# Node-RED
NODE_RED_PORT=1880

# Logging
LOG_LEVEL=info
LOG_FILE=logs/poller.log

# Development only
MOCK_PLC=false
EOF

  chmod 600 "$ENV_FILE"
  chown "${RS_USER}:${RS_USER}" "$ENV_FILE"
  ok ".env written to ${ENV_FILE}"
  source "$ENV_FILE"
fi

# =============================================================================
# 6. Chrony — configured after .env so we know both NIC interface names
#
# This node:
#   - Syncs time FROM the RideStatus Server VM via the dept NIC (stratum 3)
#   - Serves NTP TO PLC/ride-network devices via the ride NIC only
#
# The ride NIC subnet is calculated from the NIC's current IP + prefix,
# so the 'allow' directive is as tight as possible. Falls back to the
# full ride-side IP with /24 if prefix can't be determined.
# =============================================================================
header "Configuring NTP (chrony)"

RIDE_SUBNET=$(nic_subnet "${RIDE_NIC_INTERFACE:-eth0}" || true)
SERVER_DEPT_IP="${SERVER_HOST:-}"

if [[ -z "$RIDE_SUBNET" ]]; then
  # Fall back: take ride NIC IP and assume /24
  RIDE_IP=$(ip -o -4 addr show dev "${RIDE_NIC_INTERFACE:-eth0}" 2>/dev/null \
    | awk '{split($4,a,"/"); print a[1]}' | head -1 || true)
  if [[ -n "$RIDE_IP" ]]; then
    IFS=. read -r a b c _ <<< "$RIDE_IP"
    RIDE_SUBNET="${a}.${b}.${c}.0/24"
    warn "Could not determine prefix for ${RIDE_NIC_INTERFACE} — using ${RIDE_SUBNET} (assumed /24)"
    warn "Edit /etc/chrony/chrony.conf 'allow' line if this is wrong"
  else
    RIDE_SUBNET="192.168.1.0/24"
    warn "Ride NIC ${RIDE_NIC_INTERFACE} has no IP yet — using fallback ${RIDE_SUBNET}"
    warn "Edit /etc/chrony/chrony.conf 'allow' after network is up"
  fi
else
  ok "Ride NIC subnet: ${RIDE_SUBNET} (chrony will serve NTP to this range)"
fi

cat > /etc/chrony/chrony.conf << EOF
# RideStatus Edge Node — chrony config
# Generated by edge-init.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# Syncs FROM: RideStatus Server VM (${SERVER_DEPT_IP}) via dept NIC
# Serves TO:  Ride/PLC network (${RIDE_SUBNET}) via ride NIC
# NIC assignments: dept=${RIDESTATUS_NIC_INTERFACE:-eth1}  ride=${RIDE_NIC_INTERFACE:-eth0}

# Primary: sync from the RideStatus Server VM (stratum 3)
server ${SERVER_DEPT_IP} iburst prefer minpoll 4 maxpoll 6

# Fallback: internet pool if server is unreachable (requires external route)
pool pool.ntp.org iburst minpoll 6 maxpoll 10

# Serve NTP to PLC and ride-side devices only
allow ${RIDE_SUBNET}

# Serve time even if not yet synced (PLCs may boot before we have sync)
local stratum 4

makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF

systemctl enable chrony
systemctl restart chrony

# Give chrony a moment to contact the server VM
sleep 3
chronyc tracking | grep 'Leap status' \
  || warn "chrony not yet synced — check connectivity to ${SERVER_DEPT_IP}"

ok "chrony configured (server: ${SERVER_DEPT_IP}, allow: ${RIDE_SUBNET})"

# =============================================================================
# 7. Clone ridestatus-ride, install npm deps
# =============================================================================
header "Deploying ridestatus-ride"

if [[ -d "${APP_DIR}/.git" ]]; then
  info "Repo already cloned — pulling latest"
  sudo -u "$RS_USER" git -C "$APP_DIR" pull --ff-only
else
  sudo -u "$RS_USER" git clone "$APP_REPO" "$APP_DIR"
  ok "Repo cloned to ${APP_DIR}"
fi

info "Installing npm dependencies..."
sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && npm ci --omit=dev --silent"
ok "npm dependencies installed"

# Symlink .env into app directory
ln -sf "$ENV_FILE" "${APP_DIR}/.env"
chown -h "${RS_USER}:${RS_USER}" "${APP_DIR}/.env"

# =============================================================================
# 8. PM2 — install, start processes, configure startup
# =============================================================================
header "Configuring PM2"

if ! command -v pm2 &>/dev/null; then
  npm install -g pm2 --silent
  ok "PM2 installed"
else
  info "PM2 already installed ($(pm2 --version))"
fi

# Start or reload both processes (rs-poller + rs-nodered)
if sudo -u "$RS_USER" pm2 describe rs-poller &>/dev/null; then
  info "PM2 processes exist — reloading"
  sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && pm2 reload ecosystem.config.js"
else
  sudo -u "$RS_USER" bash -c "cd ${APP_DIR} && pm2 start ecosystem.config.js"
  ok "PM2 processes started (rs-poller, rs-nodered)"
fi

sudo -u "$RS_USER" pm2 save

pm2 startup systemd -u "$RS_USER" --hp "$RS_HOME" \
  | tail -n 1 | bash 2>/dev/null || true
systemctl enable "pm2-${RS_USER}" 2>/dev/null || true

ok "PM2 startup configured"

# =============================================================================
# 9. UFW firewall
#
# Dept NIC (RIDESTATUS_NIC_INTERFACE):
#   - SSH in from anywhere (admin)
#   - Ansible SSH from server VM only (SERVER_HOST)
#
# Ride NIC (RIDE_NIC_INTERFACE):
#   - NTP (123/udp) from ride subnet only (PLCs sync from this node)
#   - Node-RED UI (1880/tcp) from ride subnet only (local ops access)
#
# No inbound from the ride NIC to the dept side — edge nodes push only.
# =============================================================================
header "Configuring Firewall"

# Determine the ride NIC's own IP for binding rules
RIDE_NIC_IP=$(ip -o -4 addr show dev "${RIDE_NIC_INTERFACE:-eth0}" 2>/dev/null \
  | awk '{split($4,a,"/"); print a[1]}' | head -1 || true)

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

# SSH — allow on both NICs (tech may connect from either side)
ufw allow ssh comment "Admin SSH"

# Ansible — restrict to server VM dept IP only
ufw allow from "${SERVER_HOST}" to any port 22 proto tcp \
  comment "Ansible SSH from server VM"

# NTP — ride subnet only
ufw allow from "${RIDE_SUBNET}" to any port 123 proto udp \
  comment "NTP — ride/PLC network only"

# Node-RED UI — ride subnet only (local ops tablet/laptop on ride network)
if [[ -n "$RIDE_NIC_IP" ]]; then
  ufw allow from "${RIDE_SUBNET}" to any port 1880 proto tcp \
    comment "Node-RED UI — ride network only"
else
  ufw allow 1880/tcp comment "Node-RED UI (ride NIC not yet up — tighten after boot)"
fi

ufw --force enable
ok "Firewall configured"

# =============================================================================
# 10. Register this node with the RideStatus Server
#
# Posts to /api/bootstrap/register — server records the node's ride name,
# dept IP, and ride NIC IP. Requires SERVER_BOOTSTRAP_TOKEN.
# Non-fatal if the server is unreachable (can be retried manually).
# =============================================================================
header "Registering with Server"

DEPT_NIC_IP=$(ip -o -4 addr show dev "${RIDESTATUS_NIC_INTERFACE:-eth1}" 2>/dev/null \
  | awk '{split($4,a,"/"); print a[1]}' | head -1 || true)

if [[ -z "$DEPT_NIC_IP" ]]; then
  warn "Dept NIC (${RIDESTATUS_NIC_INTERFACE}) has no IP — skipping registration"
  warn "Run registration manually once the NIC is up:"
  warn "  curl -fsSL -X POST http://${SERVER_HOST}:${SERVER_PORT}/api/bootstrap/register \\"
  warn "    -H 'Content-Type: application/json' \\"
  warn "    -H 'X-Bootstrap-Token: ${SERVER_BOOTSTRAP_TOKEN:-<token>}' \\"
  warn "    -d '{\"ride_name\":\"${RIDE_NAME}\",\"dept_ip\":\"<this-node-dept-ip>\",\"ride_ip\":\"${RIDE_NIC_IP:-}\"}'"
else
  REGISTER_PAYLOAD=$(jq -n \
    --arg ride_name  "$RIDE_NAME" \
    --arg dept_ip    "$DEPT_NIC_IP" \
    --arg ride_ip    "${RIDE_NIC_IP:-}" \
    '{ride_name: $ride_name, dept_ip: $dept_ip, ride_ip: $ride_ip}')

  HTTP_STATUS=$(curl -fsSL -o /tmp/rs-register-resp.json -w "%{http_code}" \
    --max-time 10 \
    -X POST "http://${SERVER_HOST}:${SERVER_PORT}/api/bootstrap/register" \
    -H "Content-Type: application/json" \
    -H "X-Bootstrap-Token: ${SERVER_BOOTSTRAP_TOKEN:-}" \
    -d "$REGISTER_PAYLOAD" 2>/dev/null || echo "000")

  case "$HTTP_STATUS" in
    200|201)
      ok "Registered with server (${SERVER_HOST})"
      ;;
    409)
      info "Node already registered with server (${RIDE_NAME}) — skipping"
      ;;
    000)
      warn "Could not reach server at ${SERVER_HOST}:${SERVER_PORT}"
      warn "Node will self-register on first successful push"
      ;;
    *)
      warn "Server returned HTTP ${HTTP_STATUS} during registration"
      warn "Node will self-register on first successful push"
      ;;
  esac
fi

# =============================================================================
# Done
# =============================================================================
header "Edge Node Bootstrap Complete"

ok "Node.js:      $(node --version)"
ok "Node-RED:     $(node-red --version 2>/dev/null || echo installed)"
ok "PM2:          $(pm2 --version)"
ok "Ride:         ${RIDE_NAME}"
ok "PLC:          ${PLC_IP} (${PLC_PROTOCOL})"
ok "Dept NIC:     ${RIDESTATUS_NIC_INTERFACE} — ${DEPT_NIC_IP:-pending}"
ok "Ride NIC:     ${RIDE_NIC_INTERFACE} — ${RIDE_NIC_IP:-pending} (NTP → ${RIDE_SUBNET})"
ok "Server:       ${SERVER_HOST}:${SERVER_PORT}"
ok "App:          ${APP_DIR}"
ok "Data:         ${DATA_DIR}/ride.db"
ok "Logs:         ${LOG_DIR}"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║           ${RIDE_NAME} Edge Node Ready$(printf '%*s' $((32 - ${#RIDE_NAME})) '')║${RESET}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
printf "${BOLD}${GREEN}║  Node-RED UI:  http://%-39s║${RESET}\n" \
  "${RIDE_NIC_IP:-<ride-nic-ip>}:1880"
printf "${BOLD}${GREEN}║  Dept IP:      %-46s║${RESET}\n" \
  "${DEPT_NIC_IP:-<dept-nic-ip>}"
printf "${BOLD}${GREEN}║  NTP serving:  %-46s║${RESET}\n" \
  "${RIDE_SUBNET}"
echo -e "${BOLD}${GREEN}║                                                              ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "PM2 status:    sudo -u ridestatus pm2 status"
info "Poller logs:   sudo -u ridestatus pm2 logs rs-poller"
info "Node-RED logs: sudo -u ridestatus pm2 logs rs-nodered"
info "chrony status: chronyc tracking"
