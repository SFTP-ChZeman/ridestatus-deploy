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
#   2. Configures chrony to sync from internet NTP pool (stratum 2)
#   3. Ensures the 'ridestatus' OS user exists with correct home/permissions
#   4. Generates the Ansible SSH keypair used to manage all nodes
#      (/home/ridestatus/.ssh/ansible_ridestatus)
#   5. Configures GitHub access so Ansible can clone private repos
#      on edge nodes (deploy key or PAT — tech chooses)
#   6. Clones ridestatus-deploy repo to /home/ridestatus/ridestatus-deploy
#   7. Writes a starter Ansible inventory
#   8. Installs a systemd timer for the health-check playbook (every 5 min)
#   9. Starts a one-shot HTTP key server on port 9876 so that server.sh
#      can fetch the Ansible public key automatically.
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
GITHUB_KEY="${RS_HOME}/.ssh/github_deploy"
INVENTORY_DIR="${RS_HOME}/inventory"
LOG_DIR="${RS_HOME}/logs"
KEY_SERVER_PORT=9876
KEY_SERVER_TIMEOUT=600  # 10 minutes

# Private repos that Ansible needs to clone onto edge nodes
PRIVATE_REPOS=("git@github.com:RideStatus/ridestatus-ride.git")

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

pip3 install --quiet ansible-lint 2>/dev/null || true

ok "Packages installed"

# =============================================================================
# 2. Chrony — sync from internet NTP pool (stratum 2, independent)
# =============================================================================
header "Configuring NTP (chrony)"

cat > /etc/chrony/chrony.conf << 'EOF'
# RideStatus Ansible Controller — chrony config
pool pool.ntp.org iburst minpoll 6 maxpoll 10
allow 127.0.0.1
allow ::1
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

mkdir -p "${RS_HOME}/.ssh" "${INVENTORY_DIR}" "${LOG_DIR}"
chmod 700 "${RS_HOME}/.ssh"
chown -R "${RS_USER}:${RS_USER}" "$RS_HOME"

ok "Home directory ready: ${RS_HOME}"

# =============================================================================
# 4. Ansible SSH keypair
# =============================================================================
header "Ansible SSH Keypair"

if [[ -f "${ANSIBLE_KEY}" ]]; then
  warn "Ansible keypair already exists at ${ANSIBLE_KEY} — leaving intact"
  warn "To rotate: rm ${ANSIBLE_KEY} ${ANSIBLE_KEY}.pub and re-run"
else
  sudo -u "$RS_USER" ssh-keygen \
    -t ed25519 -f "${ANSIBLE_KEY}" -N "" -C "ansible@ridestatus" -q
  chmod 600 "${ANSIBLE_KEY}"
  chmod 644 "${ANSIBLE_KEY}.pub"
  ok "Keypair generated: ${ANSIBLE_KEY}"
fi

# =============================================================================
# 5. GitHub access — deploy key or PAT
#
# Ansible needs to clone private RideStatus repos onto edge nodes.
# Two options:
#   A) Deploy key — SSH keypair; public key added once to each private repo
#      in GitHub (Settings → Deploy keys). Most secure. Recommended.
#   B) Personal access token (PAT) — simpler, works immediately, but tied
#      to a user account. Stored as a git credential.
#
# On re-run: if credentials already configured, this section is skipped.
# =============================================================================
header "GitHub Access for Private Repos"

GITHUB_CREDS_CONFIGURED=false

# Check if already configured
if [[ -f "${GITHUB_KEY}" ]] || sudo -u "$RS_USER" git credential fill <<< "protocol=https
host=github.com" 2>/dev/null | grep -q 'password='; then
  info "GitHub credentials already configured — skipping"
  GITHUB_CREDS_CONFIGURED=true
fi

if [[ "$GITHUB_CREDS_CONFIGURED" == "false" ]]; then
  echo ""
  echo -e "${BOLD}GitHub access is needed so Ansible can clone private repos onto edge nodes.${RESET}"
  echo ""
  echo "  1) Deploy key  (recommended — SSH key scoped to RideStatus repos)"
  echo "  2) Access token (PAT — simpler, enter once, done)"
  echo ""

  GITHUB_AUTH_METHOD=""
  while true; do
    read -rp "$(echo -e "${BOLD}Choose [1]: ${RESET}")" GITHUB_AUTH_METHOD
    GITHUB_AUTH_METHOD=${GITHUB_AUTH_METHOD:-1}
    [[ "$GITHUB_AUTH_METHOD" =~ ^[12]$ ]] && break
    warn "Enter 1 or 2."
  done

  if [[ "$GITHUB_AUTH_METHOD" == "1" ]]; then
    # --- Deploy key ---
    echo ""
    if [[ -f "${GITHUB_KEY}" ]]; then
      info "GitHub deploy key already exists at ${GITHUB_KEY}"
    else
      sudo -u "$RS_USER" ssh-keygen \
        -t ed25519 -f "${GITHUB_KEY}" -N "" -C "ridestatus-ansible-deploy" -q
      chmod 600 "${GITHUB_KEY}"
      chmod 644 "${GITHUB_KEY}.pub"
      ok "GitHub deploy key generated: ${GITHUB_KEY}"
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}Action required — add this deploy key to each private repo in GitHub:${RESET}"
    echo ""
    echo -e "${BOLD}  Public key to add:${RESET}"
    echo ""
    cat "${GITHUB_KEY}.pub"
    echo ""
    echo -e "${BOLD}  Add it here (read-only, no write access needed):${RESET}"
    for repo in "${PRIVATE_REPOS[@]}"; do
      repo_name=$(basename "$repo" .git)
      echo "    https://github.com/RideStatus/${repo_name}/settings/keys"
    done
    echo ""
    echo -e "${BOLD}  Steps: Settings → Deploy keys → Add deploy key → paste key → Allow write access: NO${RESET}"
    echo ""

    # Wait for the tech to add the key before testing
    read -rp "$(echo -e "${BOLD}Press Enter once you have added the deploy key to GitHub...${RESET}")"

    # Configure SSH to use this key for github.com
    SSH_CONFIG="${RS_HOME}/.ssh/config"
    if ! grep -q "Host github.com" "$SSH_CONFIG" 2>/dev/null; then
      cat >> "$SSH_CONFIG" << EOF

Host github.com
  HostName github.com
  User git
  IdentityFile ${GITHUB_KEY}
  StrictHostKeyChecking no
  IdentitiesOnly yes
EOF
      chmod 600 "$SSH_CONFIG"
      chown "${RS_USER}:${RS_USER}" "$SSH_CONFIG"
      ok "SSH config updated for github.com"
    else
      info "SSH config for github.com already present"
    fi

    # Test access
    echo ""
    info "Testing GitHub deploy key access..."
    TEST_PASS=true
    for repo in "${PRIVATE_REPOS[@]}"; do
      repo_name=$(basename "$repo" .git)
      if sudo -u "$RS_USER" ssh -i "${GITHUB_KEY}" \
          -o StrictHostKeyChecking=no \
          -o BatchMode=yes \
          git@github.com 2>&1 | grep -q "successfully authenticated"; then
        ok "  ✓ ${repo_name} — access confirmed"
      else
        # Try git ls-remote as a more reliable test
        if sudo -u "$RS_USER" git ls-remote "$repo" HEAD &>/dev/null; then
          ok "  ✓ ${repo_name} — access confirmed"
        else
          warn "  ✗ ${repo_name} — could not verify access"
          warn "    Check that the deploy key was added to: https://github.com/RideStatus/${repo_name}/settings/keys"
          TEST_PASS=false
        fi
      fi
    done

    if [[ "$TEST_PASS" == "false" ]]; then
      warn "One or more repos could not be verified. Ansible deploys may fail."
      warn "You can re-run ansible.sh to retry, or add the key manually."
    else
      ok "All private repos accessible"
    fi

  else
    # --- Personal access token ---
    echo ""
    echo -e "${BOLD}Create a PAT at: https://github.com/settings/tokens${RESET}"
    echo "  Token type: Classic"
    echo "  Scopes needed: repo (read-only is sufficient)"
    echo ""
    read -rp "$(echo -e "${BOLD}GitHub username: ${RESET}")" GITHUB_USER
    read -rsp "$(echo -e "${BOLD}GitHub PAT (input hidden): ${RESET}")" GITHUB_PAT
    echo ""

    if [[ -z "$GITHUB_USER" || -z "$GITHUB_PAT" ]]; then
      warn "Username or PAT was empty — skipping GitHub credential storage"
      warn "Ansible deploys to edge nodes will fail until credentials are configured"
      warn "Re-run ansible.sh to configure credentials"
    else
      # Store credential using git credential store
      sudo -u "$RS_USER" git config --global credential.helper store
      echo "https://${GITHUB_USER}:${GITHUB_PAT}@github.com" \
        > "${RS_HOME}/.git-credentials"
      chmod 600 "${RS_HOME}/.git-credentials"
      chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.git-credentials"

      # Test access
      echo ""
      info "Testing PAT access..."
      TEST_PASS=true
      for repo in "${PRIVATE_REPOS[@]}"; do
        # Convert SSH URL to HTTPS for PAT auth
        https_url="https://github.com/RideStatus/$(basename "$repo" .git).git"
        if sudo -u "$RS_USER" git ls-remote "$https_url" HEAD &>/dev/null; then
          ok "  ✓ $(basename "$repo" .git) — access confirmed"
        else
          warn "  ✗ $(basename "$repo" .git) — could not verify — check PAT scopes"
          TEST_PASS=false
        fi
      done

      if [[ "$TEST_PASS" == "false" ]]; then
        warn "One or more repos could not be verified."
        warn "Ensure the PAT has 'repo' scope and access to the RideStatus org."
      else
        ok "All private repos accessible via PAT"
      fi

      # Update group_vars so Ansible uses HTTPS URLs when PAT is configured
      # (deploy key uses SSH URLs, already set in group_vars/all.yml)
      GV_ALL="${DEPLOY_DIR}/ansible/group_vars/all.yml"
      if [[ -f "$GV_ALL" ]] && grep -q 'ridestatus_ride_repo:' "$GV_ALL"; then
        sed -i "s|ridestatus_ride_repo:.*|ridestatus_ride_repo: https://github.com/RideStatus/ridestatus-ride.git|" "$GV_ALL"
        ok "group_vars/all.yml updated to use HTTPS repo URLs for PAT auth"
      fi
    fi
  fi
fi

# =============================================================================
# 6. Clone ridestatus-deploy repo
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
# 7. Ansible configuration and starter inventory
# =============================================================================
header "Ansible Configuration"

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

if [[ ! -f "${INVENTORY_DIR}/hosts.yml" ]]; then
  cat > "${INVENTORY_DIR}/hosts.yml" << 'EOF'
---
# RideStatus Ansible Inventory
# Managed by the RideStatus server management UI.
# Manual edits are preserved — the UI appends/updates entries only.
all:
  vars:
    ansible_user: ridestatus
    ansible_become: true
  children:
    servers:
      hosts: {}
    ansible_controllers:
      hosts: {}
    edge_nodes:
      hosts: {}
EOF
  chown "${RS_USER}:${RS_USER}" "${INVENTORY_DIR}/hosts.yml"
  ok "Starter inventory written"
else
  info "Inventory already exists — leaving intact"
fi

# Ensure host_vars directory exists
mkdir -p "${INVENTORY_DIR}/host_vars"
chown -R "${RS_USER}:${RS_USER}" "${INVENTORY_DIR}"

# =============================================================================
# 8. Systemd timer — health-check playbook every 5 minutes
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
ExecStart=/usr/bin/ansible-playbook ansible/playbooks/healthcheck.yml \
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

ok "Health-check timer enabled (every 5 minutes)"

# =============================================================================
# 9. Ansible vault password placeholder
# =============================================================================
if [[ ! -f "${RS_HOME}/.vault_pass" ]]; then
  echo '# Replace with vault password, then: chmod 600 ~/.vault_pass' \
    > "${RS_HOME}/.vault_pass"
  chmod 600 "${RS_HOME}/.vault_pass"
  chown "${RS_USER}:${RS_USER}" "${RS_HOME}/.vault_pass"
fi

# =============================================================================
# 10. One-shot HTTP key server
# =============================================================================
header "Starting One-Shot Ansible Key Server"

ANSIBLE_PUBKEY_CONTENT=$(cat "${ANSIBLE_KEY}.pub")
ANSIBLE_IP=$(ip -4 addr show scope global \
  | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1 || echo "<ansible-vm-ip>")

KEY_SERVER_SCRIPT=$(mktemp /tmp/ridestatus-keyserver-XXXXXX.py)
cat > "$KEY_SERVER_SCRIPT" << PYEOF
import http.server
import threading

PUBKEY_FILE = "${ANSIBLE_KEY}.pub"
PORT        = ${KEY_SERVER_PORT}
TIMEOUT     = ${KEY_SERVER_TIMEOUT}

class OneShotHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path != '/ansible_ridestatus.pub':
            self.send_response(404)
            self.end_headers()
            return

        with open(PUBKEY_FILE, 'rb') as f:
            data = f.read()

        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

        print(f'[key-server] Key fetched by {self.client_address[0]} — shutting down')
        threading.Thread(target=self.server.shutdown, daemon=True).start()

server = http.server.HTTPServer(('', PORT), OneShotHandler)
server.timeout = 1

def auto_shutdown():
    print(f'[key-server] Timeout reached ({TIMEOUT}s) — shutting down')
    server.shutdown()

timer = threading.Timer(TIMEOUT, auto_shutdown)
timer.daemon = True
timer.start()

print(f'[key-server] Listening on port {PORT}')
try:
    server.serve_forever()
finally:
    timer.cancel()
PYEOF

python3 "$KEY_SERVER_SCRIPT" >> "${LOG_DIR}/keyserver.log" 2>&1 &
KEY_SERVER_PID=$!
echo "$KEY_SERVER_PID" > /tmp/ridestatus-keyserver.pid

sleep 1
if ! kill -0 "$KEY_SERVER_PID" 2>/dev/null; then
  warn "Key server failed to start — check ${LOG_DIR}/keyserver.log"
else
  ok "Key server running (PID ${KEY_SERVER_PID})"
fi

trap 'kill "$KEY_SERVER_PID" 2>/dev/null || true; rm -f "$KEY_SERVER_SCRIPT" /tmp/ridestatus-keyserver.pid' EXIT

# =============================================================================
# Done
# =============================================================================
header "Ansible Bootstrap Complete"

ok "ridestatus-deploy: ${DEPLOY_DIR}"
ok "Inventory:         ${INVENTORY_DIR}/hosts.yml"
ok "host_vars:         ${INVENTORY_DIR}/host_vars/"
ok "Ansible log:       ${LOG_DIR}/ansible.log"
ok "GitHub access:     configured"

echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${YELLOW}║              Ansible Key Server Ready                        ║${RESET}"
echo -e "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${YELLOW}║  server.sh fetches the Ansible public key from:              ║${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${CYAN}║  http://${ANSIBLE_IP}:${KEY_SERVER_PORT}/ansible_ridestatus.pub${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${YELLOW}║  Exits after one fetch or 10 minutes.                        ║${RESET}"
echo -e "${BOLD}${YELLOW}║                                                              ║${RESET}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Run bootstrap/server.sh on the Server VM now."
info "It will fetch the key automatically if given this VM's IP."

wait "$KEY_SERVER_PID" 2>/dev/null || true
rm -f "$KEY_SERVER_SCRIPT" /tmp/ridestatus-keyserver.pid
ok "Key server stopped."
