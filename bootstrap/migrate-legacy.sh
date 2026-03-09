#!/usr/bin/env bash
# =============================================================================
# RideStatus — Legacy Pi Migration (migrate-legacy.sh)
# https://github.com/RideStatus/ridestatus-deploy
#
# Migrates a Raspberry Pi running the previous ride status system to RideStatus.
# DO NOT re-image the Pi — run this script instead. It is non-destructive
# (backs up old flows) and hands off to edge-init.sh when done.
#
# Known state of legacy Pis:
#   - OS user:   'sftp'  (home: /home/sftp/)
#   - Node-RED:  installed via official one-line installer (nodered.org)
#                — systemd service: 'nodered'
#                — flows at: /home/sftp/.node-red/
#                — Node.js likely older than 22, possibly via nvm
#   - NTP:       ntpsec installed — must be removed (conflicts with chrony)
#   - No PM2, no RideStatus code
#   - NIC names: eth0 = Ride network, eth1 = RideStatus/dept network
#
# What this script does:
#   1.  Detects whether this looks like a legacy Pi (checks for nodered
#       service, ~/.node-red/, old 'sftp' user). Aborts cleanly if not found.
#   2.  Shows exactly what was found and asks for confirmation before touching
#       anything.
#   3.  Stops and disables the nodered systemd service.
#   4.  Backs up /home/sftp/.node-red/flows*.json to a timestamped archive
#       in /home/sftp/ (non-destructive — old flows are kept for reference).
#   5.  Removes Node-RED (npm uninstall -g node-red) and ~/.node-red/.
#   6.  Removes ntpsec (conflicts with chrony which edge-init.sh installs).
#   7.  Removes nvm if present (left by the official Node-RED installer).
#   8.  Upgrades Node.js to 22 via NodeSource if not already at 22.
#   9.  Cleans up any stray PM2 instances (defensive — not expected).
#  10.  Creates the 'ridestatus' OS user if it doesn't exist, preserving
#       the existing 'sftp' user (leave it intact — don't break anything).
#  11.  Hands off to edge-init.sh to complete the RideStatus installation.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap/migrate-legacy.sh | sudo bash
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';     RESET='\033[0m'

info()   { echo -e "${CYAN}[migrate]${RESET} $*"; }
ok()     { echo -e "${GREEN}[migrate]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[migrate]${RESET} $*"; }
die()    { echo -e "${RED}[migrate] ERROR:${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo bash migrate-legacy.sh)"

EDGE_INIT_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap/edge-init.sh"
LEGACY_USER="sftp"
LEGACY_HOME="/home/${LEGACY_USER}"
LEGACY_NODERED_DIR="${LEGACY_HOME}/.node-red"
BACKUP_DIR="${LEGACY_HOME}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# =============================================================================
# 1. Detection — what is actually on this Pi?
# =============================================================================
header "Legacy System Detection"

FOUND_SERVICE=false
FOUND_NODERED_DIR=false
FOUND_SFTP_USER=false
FOUND_NODERED_BIN=false
FOUND_NVM=false
FOUND_NTPSEC=false
FOUND_PM2=false

systemctl list-unit-files nodered.service &>/dev/null \
  && systemctl list-unit-files nodered.service | grep -q nodered \
  && FOUND_SERVICE=true || true

[[ -d "$LEGACY_NODERED_DIR" ]] && FOUND_NODERED_DIR=true || true
id "$LEGACY_USER" &>/dev/null && FOUND_SFTP_USER=true || true
command -v node-red &>/dev/null && FOUND_NODERED_BIN=true || true
[[ -d "${LEGACY_HOME}/.nvm" ]] && FOUND_NVM=true || true
dpkg -l ntpsec 2>/dev/null | grep -q '^ii' && FOUND_NTPSEC=true || true
command -v pm2 &>/dev/null && FOUND_PM2=true || true

echo ""
echo -e "${BOLD}What was found on this Pi:${RESET}"
echo "  nodered systemd service:  $($FOUND_SERVICE  && echo "${GREEN}YES${RESET}" || echo "no")"
echo -e "  /home/sftp/.node-red/:    $($FOUND_NODERED_DIR && echo "${GREEN}YES${RESET}" || echo "no")"
echo -e "  'sftp' OS user:           $($FOUND_SFTP_USER   && echo "${GREEN}YES${RESET}" || echo "no")"
echo -e "  node-red in PATH:         $($FOUND_NODERED_BIN && echo "${GREEN}YES${RESET}" || echo "no")"
echo -e "  nvm installation:         $($FOUND_NVM         && echo "${YELLOW}YES (will remove)${RESET}" || echo "no")"
echo -e "  ntpsec installed:         $($FOUND_NTPSEC      && echo "${YELLOW}YES (will remove — conflicts with chrony)${RESET}" || echo "no")"
echo -e "  PM2:                      $($FOUND_PM2         && echo "${YELLOW}YES (will clean up)${RESET}" || echo "no")"
echo ""

# Require at least one strong indicator to proceed
if ! $FOUND_SERVICE && ! $FOUND_NODERED_DIR && ! $FOUND_SFTP_USER; then
  warn "This does not appear to be a legacy RideStatus Pi."
  warn "  Expected: nodered service, /home/sftp/.node-red/, or 'sftp' user."
  warn "  None of these were found."
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo "  1) Run edge-init.sh directly (fresh install)"
  echo "  2) Abort and inspect manually"
  echo ""
  read -rp "$(echo -e "${BOLD}Choice [1/2]: ${RESET}")" choice
  case "${choice:-1}" in
    1)
      info "Fetching and running edge-init.sh..."
      curl -fsSL "$EDGE_INIT_URL" | bash
      exit 0
      ;;
    *)
      info "Aborted. No changes made."
      exit 0
      ;;
  esac
fi

# =============================================================================
# 2. Confirmation before any changes
# =============================================================================
echo -e "${BOLD}${YELLOW}This will make the following changes:${RESET}"
$FOUND_SERVICE     && echo "  • Stop and disable the 'nodered' systemd service"
$FOUND_NODERED_DIR && echo "  • Back up flows to ${BACKUP_DIR}/nodered-flows-backup-${TIMESTAMP}.tar.gz"
$FOUND_NODERED_DIR && echo "  • Remove /home/sftp/.node-red/"
$FOUND_NODERED_BIN && echo "  • Uninstall node-red npm package"
$FOUND_NTPSEC      && echo "  • Remove ntpsec (replaced by chrony)"
$FOUND_NVM         && echo "  • Remove nvm from /home/sftp/.nvm"
                       echo "  • Upgrade Node.js to 22 if not already at 22"
$FOUND_PM2         && echo "  • Clean up PM2 processes"
                       echo "  • Create 'ridestatus' OS user (sftp user left intact)"
                       echo "  • Run edge-init.sh to complete RideStatus installation"
echo ""
echo -e "${YELLOW}  The 'sftp' OS user and home directory are NOT removed.${RESET}"
echo ""
read -rp "$(echo -e "${BOLD}Type 'yes' to proceed or anything else to abort: ${RESET}")" confirm
[[ "$confirm" == "yes" ]] || { info "Aborted. No changes made."; exit 0; }

# =============================================================================
# 3. Stop and disable nodered service
# =============================================================================
if $FOUND_SERVICE; then
  header "Stopping nodered Service"
  systemctl stop nodered  2>/dev/null && ok "nodered stopped"  || warn "nodered was not running"
  systemctl disable nodered 2>/dev/null && ok "nodered disabled" || warn "nodered was already disabled"
fi

# =============================================================================
# 4. Back up flows
# =============================================================================
if $FOUND_NODERED_DIR; then
  header "Backing Up Node-RED Flows"
  FLOW_FILES=()
  while IFS= read -r -d '' f; do
    FLOW_FILES+=("$f")
  done < <(find "$LEGACY_NODERED_DIR" -name 'flows*.json' -print0 2>/dev/null || true)

  if [[ ${#FLOW_FILES[@]} -gt 0 ]]; then
    BACKUP_ARCHIVE="${BACKUP_DIR}/nodered-flows-backup-${TIMESTAMP}.tar.gz"
    tar -czf "$BACKUP_ARCHIVE" -C "$LEGACY_HOME" \
      $(printf '.node-red/%s\n' "${FLOW_FILES[@]##*/}") 2>/dev/null || \
    tar -czf "$BACKUP_ARCHIVE" -C "$LEGACY_HOME" .node-red/ 2>/dev/null || true
    chown "${LEGACY_USER}:${LEGACY_USER}" "$BACKUP_ARCHIVE" 2>/dev/null || true
    ok "Flows backed up: ${BACKUP_ARCHIVE}"
    info "Flow files found:"
    for f in "${FLOW_FILES[@]}"; do echo "  $f"; done
  else
    info "No flows*.json files found in ${LEGACY_NODERED_DIR} — nothing to back up"
  fi
fi

# =============================================================================
# 5. Remove Node-RED
# =============================================================================
header "Removing Node-RED"

if $FOUND_NODERED_BIN; then
  npm uninstall -g node-red 2>/dev/null && ok "node-red npm package removed" \
    || warn "npm uninstall returned non-zero — may already be removed"
fi

if $FOUND_NODERED_DIR; then
  rm -rf "$LEGACY_NODERED_DIR"
  ok "Removed ${LEGACY_NODERED_DIR}"
fi

# Also remove the nodered service unit file if it's still present
if [[ -f /etc/systemd/system/nodered.service ]]; then
  rm -f /etc/systemd/system/nodered.service
  systemctl daemon-reload
  ok "nodered service unit file removed"
fi

# =============================================================================
# 6. Remove ntpsec
# ntpsec conflicts with chrony. edge-init.sh installs chrony.
# =============================================================================
if $FOUND_NTPSEC; then
  header "Removing ntpsec"
  systemctl stop ntpsec  2>/dev/null || true
  systemctl disable ntpsec 2>/dev/null || true
  apt-get remove -y --purge ntpsec ntpsec-ntpdate 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  ok "ntpsec removed"
fi

# =============================================================================
# 7. Remove nvm
# The official Node-RED one-line installer may have installed Node.js via nvm.
# We'll use NodeSource instead, which is system-wide and compatible with PM2.
# =============================================================================
if $FOUND_NVM; then
  header "Removing nvm"
  NVM_DIR="${LEGACY_HOME}/.nvm"
  rm -rf "$NVM_DIR"
  ok "Removed ${NVM_DIR}"

  # Clean nvm lines from sftp user's shell profile files
  for profile in \
    "${LEGACY_HOME}/.bashrc" \
    "${LEGACY_HOME}/.bash_profile" \
    "${LEGACY_HOME}/.profile"; do
    if [[ -f "$profile" ]]; then
      sed -i '/NVM_DIR/d; /nvm.sh/d; /bash_completion.*nvm/d' "$profile"
      ok "Cleaned nvm references from ${profile}"
    fi
  done
fi

# =============================================================================
# 8. Upgrade Node.js to 22
# =============================================================================
header "Node.js Version Check"

CURRENT_NODE_MAJOR=0
if command -v node &>/dev/null; then
  CURRENT_NODE_MAJOR=$(node --version 2>/dev/null | grep -o 'v[0-9]*' | grep -o '[0-9]*' | head -1 || echo 0)
fi

if (( CURRENT_NODE_MAJOR >= 22 )); then
  ok "Node.js $(node --version) already installed — no upgrade needed"
else
  if (( CURRENT_NODE_MAJOR > 0 )); then
    info "Node.js v${CURRENT_NODE_MAJOR} found — upgrading to 22"
  else
    info "Node.js not found — installing 22"
  fi

  # Remove any existing NodeSource repo to avoid conflicts
  rm -f /etc/apt/sources.list.d/nodesource.list \
        /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true

  # Install Node.js 22 via NodeSource
  apt-get install -y --no-install-recommends curl ca-certificates gnupg 2>/dev/null || true
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y --no-install-recommends nodejs
  ok "Node.js upgraded: $(node --version)"
fi

# =============================================================================
# 9. Clean up stray PM2 (defensive — not expected on legacy Pis)
# =============================================================================
if $FOUND_PM2; then
  header "Cleaning Up PM2"
  pm2 delete all 2>/dev/null || true
  pm2 save --force 2>/dev/null || true
  # Remove any PM2 startup hook for the sftp user
  systemctl disable "pm2-${LEGACY_USER}" 2>/dev/null || true
  rm -f "/etc/systemd/system/pm2-${LEGACY_USER}.service" 2>/dev/null || true
  systemctl daemon-reload
  ok "PM2 cleaned up"
fi

# =============================================================================
# 10. Create 'ridestatus' OS user
# The 'sftp' user is left intact — edge-init.sh will create 'ridestatus'.
# We note the NIC mapping here for the tech so edge-init.sh questions are easy.
# =============================================================================
header "Pre-flight for edge-init.sh"

echo ""
echo -e "${BOLD}${CYAN}Legacy NIC assignments on this Pi:${RESET}"
echo "  eth0 = Ride network      (PLC comms, NTP serving)"
echo "  eth1 = RideStatus/dept   (data push to server, Ansible SSH)"
echo ""
echo -e "  When edge-init.sh asks for NIC assignments, use these values."
echo ""

# Show current interface state to help the tech confirm
echo -e "${BOLD}Current interface state:${RESET}"
ip -o link show | grep -v '^[0-9]*: lo' | awk -F': ' '{print "  "$2}' | while read -r iface; do
  iface=$(echo "$iface" | awk '{print $1}')
  state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
  mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "unknown")
  ip_addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -1 || echo "none")
  echo "  ${iface}  state=${state}  MAC=${mac}  IP=${ip_addr:-none}"
done
echo ""

# =============================================================================
# Done — hand off to edge-init.sh
# =============================================================================
header "Migration Complete — Handing Off to edge-init.sh"

ok "nodered service removed"
ok "Node-RED removed"
$FOUND_NTPSEC && ok "ntpsec removed"
$FOUND_NVM    && ok "nvm removed"
ok "Node.js: $(node --version)"
ok "Flows backed up (if any) in ${BACKUP_DIR}/"
ok "'sftp' user and home directory left intact"
echo ""
info "Starting edge-init.sh now..."
echo ""

curl -fsSL "$EDGE_INIT_URL" | bash
