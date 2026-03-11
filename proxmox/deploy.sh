#!/usr/bin/env bash
# =============================================================================
# RideStatus — Proxmox Deploy Script
# https://github.com/RideStatus/ridestatus-deploy
#
# Run once per Proxmox host as root.
# Creates RideStatus Server VM and/or Ansible Controller VM.
#
# SSH approach:
#   A temporary ed25519 keypair is generated at startup and injected into
#   cloud-init alongside the tech's admin key. The script uses the temp key
#   for bootstrap SSH connections, falling back to the admin key if needed
#   (e.g. when re-running against VMs already booted from a prior run).
#   The fallback only triggers on SSH auth failure (exit 255), not on remote
#   script errors — preventing bootstrap scripts from running twice.
#   The temp key is deleted on exit.
#
# Cloud-init approach:
#   Uses --cicustom user= to supply a full cloud-config snippet written to
#   /var/lib/vz/snippets/. IMPORTANT: when --cicustom user= is set, Proxmox's
#   native --ciuser and --sshkeys are silently ignored by cloud-init — the
#   snippet IS the entire user-data. Therefore the snippet must handle user
#   creation, SSH key injection, AND qemu-guest-agent installation.
#   Network config (--ipconfig, --nameserver) lives in a separate Proxmox
#   "network-data" section and is NOT affected by --cicustom user=.
#   After all qm set calls, `qm cloudinit update` rebuilds the ISO before
#   the VM starts. pvesh JSON is used throughout for storage inspection.
#
# USB NIC naming:
#   After each VM boots, the QEMU guest agent is queried for real NIC names.
#   Any USB passthrough NIC netplan placeholders are patched in-place.
#
# Ansible public key handoff:
#   When BOTH VMs are on this host, deploy.sh passes ANSIBLE_KEY_URL to
#   server.sh pointing to ansible.sh's one-shot key server. server.sh fetches
#   the key directly — no shell quoting issues with multi-layer escaping.
#   When only one VM is on this host, server.sh prompts for the key URL
#   (which ansible.sh printed) and fetches it itself.
#
# NIC roles:
#   Each vNIC is tagged with a role (Department/RideStatus or Corporate).
#   The Department NIC carries edge node traffic, the management UI, and NTP.
#   The Corporate NIC carries internet and corporate VLAN traffic.
#   These roles are passed to server.sh as RS_DEPT_NIC_HINT / RS_CORP_NIC_HINT
#   so it can pre-populate the correct interface names in .env.
#
# Usage: bash proxmox/deploy.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m';  YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m';      RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()    { err "$*"; exit 1; }
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

pick_menu() {
  local -n _pick=$1; local msg=$2; shift 2; local opts=("$@")
  echo -e "${BOLD}${msg}${RESET}"
  for i in "${!opts[@]}"; do echo "  $((i+1))) ${opts[$i]}"; done
  while true; do
    read -rp "Choice: " _pick
    if [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#opts[@]} )); then
      _pick=$(( _pick - 1 )); break
    fi
    warn "Enter a number between 1 and ${#opts[@]}."
  done
}

confirm() {
  local ans
  while true; do
    read -rp "$(echo -e "${BOLD}$1${RESET} [y/n]: ")" ans
    case "$ans" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; *) warn "Please answer y or n." ;; esac
  done
}

# Helper: read MAC for an interface
iface_mac() { cat "/sys/class/net/${1}/address" 2>/dev/null || echo "unknown"; }

# Helper: get all storage config as JSON via pvesh (reliable, no awk)
storage_json() { pvesh get /storage --output-format json 2>/dev/null || echo '[]'; }

# Helper: purge an IP from /root/.ssh/known_hosts so manual SSH works cleanly
# after a VM is recreated at the same IP. The script itself uses
# UserKnownHostsFile=/dev/null and is unaffected either way.
purge_known_host() {
  local ip=$1
  if [[ -f /root/.ssh/known_hosts ]]; then
    ssh-keygen -f /root/.ssh/known_hosts -R "$ip" &>/dev/null || true
  fi
}

# Helper: prompt for a static IP with CIDR prefix, detecting if the tech
# forgot the prefix length and asking for the subnet mask in that case.
# Sets the named variable to a valid x.x.x.x/prefix string.
prompt_ip_cidr() {
  local -n _ipcidr=$1; local label=$2
  while true; do
    prompt_required _ipcidr "Static IP and prefix for ${label} (e.g. 10.15.140.101/25)"
    if [[ "$_ipcidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
      # Looks like a valid CIDR — do a quick range check on the prefix
      local pfx="${_ipcidr##*/}"
      if (( pfx >= 1 && pfx <= 32 )); then
        break
      else
        warn "Prefix length /${pfx} is out of range (1-32). Try again."
        continue
      fi
    elif [[ "$_ipcidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # IP entered without a prefix — ask for the subnet mask
      warn "No prefix length detected. Please enter the subnet mask for ${_ipcidr}."
      local mask
      prompt_required mask "Subnet mask (e.g. 255.255.255.128 or /25)"
      mask="${mask#/}"   # strip leading slash if they typed /25
      if [[ "$mask" =~ ^[0-9]+$ ]]; then
        # They gave a prefix number directly
        local pfx="$mask"
        if (( pfx >= 1 && pfx <= 32 )); then
          _ipcidr="${_ipcidr}/${pfx}"
          break
        else
          warn "Prefix /${pfx} is out of range. Try again."
        fi
      elif [[ "$mask" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Convert dotted-decimal mask to prefix length via python3
        local pfx
        pfx=$(python3 -c "
import ipaddress, sys
try:
    n = ipaddress.IPv4Network('0.0.0.0/' + sys.argv[1], strict=False)
    print(n.prefixlen)
except Exception:
    print('')
" "$mask" 2>/dev/null || true)
        if [[ -n "$pfx" ]] && (( pfx >= 1 && pfx <= 32 )); then
          _ipcidr="${_ipcidr}/${pfx}"
          break
        else
          warn "Could not parse subnet mask '${mask}'. Try again."
        fi
      else
        warn "Could not parse '${mask}'. Enter a mask like 255.255.255.0 or a prefix like 24."
      fi
    else
      warn "Expected an IP address like 10.15.140.101 or 10.15.140.101/25. Try again."
    fi
  done
}

# =============================================================================
# Preflight
# =============================================================================
header "RideStatus Proxmox Deploy"

[[ $EUID -eq 0 ]] || die "This script must be run as root."
command -v pvesh    >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox host?"
command -v pvesm    >/dev/null 2>&1 || die "pvesm not found — is this a Proxmox host?"
command -v qm       >/dev/null 2>&1 || die "qm not found — is this a Proxmox host?"
command -v lsusb    >/dev/null 2>&1 || die "lsusb not found (apt install usbutils)"
command -v ssh      >/dev/null 2>&1 || die "ssh not found"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
command -v python3  >/dev/null 2>&1 || die "python3 not found"
command -v curl     >/dev/null 2>&1 || die "curl not found"

PROXMOX_NODE=$(hostname)
info "Proxmox node: ${PROXMOX_NODE}"

# =============================================================================
# Detect suitable storages for OS disk, cloud-init drive, and snippets
# =============================================================================
header "Detecting Storage"

get_storage_field() {
  local name=$1 field=$2
  storage_json | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s.get('storage') == '${name}':
        print(s.get('${field}', ''))
        break
" 2>/dev/null || true
}

find_dir_storage() {
  storage_json | python3 -c "
import sys, json
stores = json.load(sys.stdin)
for s in stores:
    if s.get('storage') == 'local' and s.get('type') == 'dir':
        print('local')
        sys.exit(0)
for s in stores:
    if s.get('type') == 'dir':
        print(s.get('storage', ''))
        sys.exit(0)
" 2>/dev/null || true
}

ensure_content_type() {
  local storage=$1 ctype=$2
  local current_content
  current_content=$(get_storage_field "$storage" "content")

  if echo "$current_content" | grep -qw "$ctype"; then
    info "Storage '${storage}' already has '${ctype}' content type"
    return 0
  fi

  info "Enabling '${ctype}' content type on storage '${storage}'..."
  local new_content
  if [[ -n "$current_content" ]]; then
    new_content="${current_content},${ctype}"
  else
    new_content="iso,vztmpl,backup,images,snippets"
  fi

  pvesm set "$storage" --content "$new_content" \
    || die "Failed to enable '${ctype}' content on storage '${storage}'"
  ok "'${ctype}' content type enabled on '${storage}'"
}

DISK_STORAGE=""
CI_STORAGE=""

if pvesm status --storage "local-lvm" &>/dev/null 2>&1; then
  DISK_STORAGE="local-lvm"
  info "OS disk storage: local-lvm"
else
  DISK_STORAGE=$(storage_json | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if 'images' in s.get('content', ''):
        print(s.get('storage', ''))
        break
" 2>/dev/null || true)
  [[ -n "$DISK_STORAGE" ]] || die "No images-capable storage found for OS disk"
  info "OS disk storage: ${DISK_STORAGE} (local-lvm not found)"
fi

CI_STORAGE=$(find_dir_storage)
[[ -n "$CI_STORAGE" ]] || die "No directory-type storage found for cloud-init drive."
ensure_content_type "$CI_STORAGE" "images"
ensure_content_type "$CI_STORAGE" "snippets"
info "Cloud-init / snippets storage: ${CI_STORAGE}"

SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# =============================================================================
# Temporary deploy keypair
# =============================================================================
DEPLOY_KEY_DIR=$(mktemp -d /tmp/ridestatus-deploy-XXXXXX)
DEPLOY_KEY="${DEPLOY_KEY_DIR}/id_ed25519"
DEPLOY_PUBKEY="${DEPLOY_KEY}.pub"

ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "ridestatus-deploy-temp" -q
DEPLOY_PUBKEY_CONTENT=$(cat "$DEPLOY_PUBKEY")
ok "Temporary deploy keypair generated (deleted on exit)"

ADMIN_KEY_PATH="/root/ridestatus-admin-key"

cleanup() {
  rm -rf "$DEPLOY_KEY_DIR"
  rm -f "${SNIPPET_DIR}/ridestatus-userdata-"*.yaml 2>/dev/null || true
}
trap cleanup EXIT

# deploy_ssh [-t] IP [CMD...]
# Tries the temporary deploy key first; falls back to the admin key ONLY on
# SSH authentication failure (exit code 255). Remote script errors (any other
# non-zero exit) are returned as-is without retrying — this prevents bootstrap
# scripts from running twice when a script fails partway through.
#
# Pass -t as the first argument to allocate a pseudo-TTY for the remote
# session. This is required when the remote script uses /dev/tty for
# interactive prompts (e.g. server.sh Park Configuration). Double -t is used
# to force TTY allocation even when deploy.sh itself has no TTY (e.g. when
# run via bash <(curl ...)).
#
# BatchMode is disabled in TTY mode so interactive prompts can function.
deploy_ssh() {
  local tty_flag=false
  if [[ "${1:-}" == "-t" ]]; then
    tty_flag=true
    shift
  fi
  local ip=$1; shift
  local ssh_opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=5
  )
  if $tty_flag; then
    # -t -t: force TTY even when local stdin is not a TTY (bash <(curl ...))
    ssh_opts+=(-t -t)
  else
    ssh_opts+=(-o BatchMode=yes)
  fi
  local exit_code=0
  ssh -i "$DEPLOY_KEY" "${ssh_opts[@]}" "ridestatus@${ip}" "$@" 2>/dev/null
  exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    return 0
  fi
  # Exit code 255 = SSH-level failure (auth, connection refused, etc.)
  # Any other code = remote command failed — do NOT retry; return the error.
  if [[ $exit_code -ne 255 ]]; then
    return $exit_code
  fi
  if [[ -f "$ADMIN_KEY_PATH" ]]; then
    ssh -i "$ADMIN_KEY_PATH" "${ssh_opts[@]}" "ridestatus@${ip}" "$@"
    return $?
  fi
  return 1
}

# =============================================================================
# Detect physical interfaces and bridges
# =============================================================================
header "Detecting Network Interfaces"

mapfile -t ALL_IFACES < <(
  ip -o link show | awk -F': ' '{print $2}' \
  | grep -v '^lo$' \
  | grep -v '@' \
  | grep -Ev '^(vmbr|tap|veth|fwbr|fwpr|fwln)'
)

mapfile -t EXISTING_BRIDGES < <(
  ip -o link show | awk -F': ' '{print $2}' | grep '^vmbr' | grep -v '@' || true
)

echo ""
info "Physical interfaces found:"
for iface in "${ALL_IFACES[@]}"; do
  mac=$(iface_mac "$iface")
  state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
  is_usb=""
  readlink -f "/sys/class/net/${iface}/device" 2>/dev/null | grep -q '/usb' && is_usb=" [USB]"
  echo "  ${iface}  MAC=${mac}  state=${state}${is_usb}"
done

if [[ ${#EXISTING_BRIDGES[@]} -gt 0 ]]; then
  info "Existing Proxmox bridges:"
  for br in "${EXISTING_BRIDGES[@]}"; do
    echo "  ${br}"
  done
fi

# =============================================================================
# Enumerate USB NICs
# =============================================================================
header "USB NIC Detection"

declare -A USB_NIC_VENDOR_PRODUCT=()
declare -A USB_NIC_BUS_PATH=()
declare -A USB_NIC_MAC=()
declare -A USB_BUS_PATH_CLAIMED_BY=()
declare -a FREE_USB_NICS=()

for iface in "${ALL_IFACES[@]}"; do
  syspath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
  [[ -z "$syspath" ]] && continue
  echo "$syspath" | grep -q '/usb' || continue

  usb_dir=$(echo "$syspath" | sed 's|/[^/]*$||')
  vp=""
  while [[ "$usb_dir" =~ /usb ]]; do
    v=$(cat "${usb_dir}/idVendor"  2>/dev/null || true)
    p=$(cat "${usb_dir}/idProduct" 2>/dev/null || true)
    if [[ -n "$v" && -n "$p" ]]; then
      vp="${v}:${p}"
      break
    fi
    usb_dir=$(dirname "$usb_dir")
  done
  [[ -z "$vp" ]] && continue
  USB_NIC_VENDOR_PRODUCT["$iface"]="$vp"
  USB_NIC_MAC["$iface"]=$(iface_mac "$iface")

  bus_path=$(echo "$syspath" | grep -oP '(?<=/devices/)[\d]+-[\d.]+(?=/)' | head -1 || true)
  [[ -n "$bus_path" ]] && USB_NIC_BUS_PATH["$iface"]="$bus_path"
done

if [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -gt 0 ]]; then
  mapfile -t ALL_VMIDS < <(
    pvesh get "/nodes/${PROXMOX_NODE}/qemu" --output-format json 2>/dev/null \
    | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' || true
  )

  declare -A VP_TO_BUS_PATHS=()
  for iface in "${!USB_NIC_BUS_PATH[@]}"; do
    local_vp=${USB_NIC_VENDOR_PRODUCT[$iface]:-}
    local_bp=${USB_NIC_BUS_PATH[$iface]}
    [[ -z "$local_vp" ]] && continue
    existing=${VP_TO_BUS_PATHS[$local_vp]:-}
    VP_TO_BUS_PATHS["$local_vp"]="${existing:+$existing }$local_bp"
  done

  for vmid in "${ALL_VMIDS[@]}"; do
    vm_config=$(pvesh get "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
                --output-format json 2>/dev/null || true)

    while IFS= read -r usb_entry; do
      raw=$(echo "$usb_entry" | grep -o 'host=[^ ",]*' | sed 's/host=//' || true)
      [[ -z "$raw" ]] && continue

      if echo "$raw" | grep -qP '^\d+-[\d.]+$'; then
        USB_BUS_PATH_CLAIMED_BY["$raw"]="$vmid"
      elif echo "$raw" | grep -qP '^[0-9a-f]{4}:[0-9a-f]{4}$'; then
        known_paths=${VP_TO_BUS_PATHS[$raw]:-}
        for bp in $known_paths; do
          USB_BUS_PATH_CLAIMED_BY["$bp"]="$vmid"
        done
      fi
    done < <(echo "$vm_config" | grep -o '"usb[0-9]*":"[^"]*"' || true)
  done
fi

for iface in "${!USB_NIC_VENDOR_PRODUCT[@]}"; do
  bp=${USB_NIC_BUS_PATH[$iface]:-}
  if [[ -z "$bp" ]]; then
    warn "Could not determine bus path for ${iface} — excluding from free list to be safe"
    continue
  fi
  if [[ -z "${USB_BUS_PATH_CLAIMED_BY[$bp]:-}" ]]; then
    FREE_USB_NICS+=("$iface")
  else
    info "USB NIC ${iface} (bus ${bp}, MAC ${USB_NIC_MAC[$iface]:-unknown}) already claimed by VM ${USB_BUS_PATH_CLAIMED_BY[$bp]} — skipping"
  fi
done

if   [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -eq 0 ]]; then
  info "No USB NICs detected."
elif [[ ${#FREE_USB_NICS[@]} -eq 0 ]]; then
  warn "All USB NICs already passed through to existing VMs."
else
  info "Free USB NICs available:"
  for iface in "${FREE_USB_NICS[@]}"; do
    mac=${USB_NIC_MAC[$iface]:-unknown}
    bp=${USB_NIC_BUS_PATH[$iface]:-unknown}
    echo "  ${iface}  MAC=${mac}  bus=${bp}  vendor:product=${USB_NIC_VENDOR_PRODUCT[$iface]}"
  done
fi

# =============================================================================
# VM selection
# =============================================================================
header "VM Selection"

CREATE_SERVER=false
CREATE_ANSIBLE=false
pick_idx=0
pick_menu pick_idx "Which VMs should be created on this host?" \
  "Both (recommended)" \
  "Ansible Controller only" \
  "RideStatus Server only"

case $pick_idx in
  0) CREATE_SERVER=true; CREATE_ANSIBLE=true ;;
  1) CREATE_ANSIBLE=true ;;
  2) CREATE_SERVER=true ;;
esac

$CREATE_ANSIBLE && info "Will create: Ansible Controller VM"
$CREATE_SERVER  && info "Will create: RideStatus Server VM"

declare -a SESSION_CLAIMED_USB=()
declare -A BRIDGE_IFACE_MAP=()

# =============================================================================
# NIC configuration helper
# =============================================================================
# NIC_ROLE_DEPT_IDX and NIC_ROLE_CORP_IDX track which vNIC index was designated
# as the Department and Corporate NICs respectively (for passing hints to server.sh)
NIC_ROLE_DEPT_IDX=-1
NIC_ROLE_CORP_IDX=-1

configure_vm_nics() {
  local vm_label=$1
  VM_NICS_TYPE=(); VM_NICS_LABEL=(); VM_NICS_BRIDGE=()
  VM_NICS_USB=();  VM_NICS_MAC=();   VM_NICS_IP=(); VM_NICS_GW=(); VM_NICS_DNS=()
  VM_NICS_ROLE=()   # "dept", "corp", or "other"
  NIC_ROLE_DEPT_IDX=-1
  NIC_ROLE_CORP_IDX=-1

  local nic_num=1
  while true; do
    echo ""
    echo -e "${BOLD}--- ${vm_label}: vNIC${nic_num} ---${RESET}"

    # --- Network name / purpose ---
    local net_label
    prompt_required net_label \
      "What network does vNIC${nic_num} connect to? (e.g. Department, Corporate VLAN)"

    # --- NIC role ---
    # The Department/RideStatus NIC carries edge node traffic, the management
    # UI, and NTP. The Corporate NIC carries internet and corporate VLAN traffic.
    # This tells server.sh which interface to bind services to.
    local role_opts=(
      "Department / RideStatus network  (edge traffic, management UI, NTP)"
      "Corporate / external network     (internet, corporate VLAN)"
      "Other / not applicable"
    )
    local role_idx=0
    # Auto-suggest: first NIC defaults to Department, second to Corporate
    if   (( nic_num == 1 )); then role_idx=0
    elif (( nic_num == 2 )); then role_idx=1
    fi
    echo ""
    echo -e "${BOLD}What role does this NIC play?${RESET}"
    for i in "${!role_opts[@]}"; do echo "  $((i+1))) ${role_opts[$i]}"; done
    while true; do
      read -rp "Choice [$(( role_idx + 1 ))]: " role_pick
      role_pick="${role_pick:-$(( role_idx + 1 ))}"
      if [[ "$role_pick" =~ ^[0-9]+$ ]] && (( role_pick >= 1 && role_pick <= 3 )); then
        role_idx=$(( role_pick - 1 )); break
      fi
      warn "Enter 1, 2, or 3."
    done
    local nic_role="other"
    case $role_idx in
      0) nic_role="dept" ;;
      1) nic_role="corp" ;;
      2) nic_role="other" ;;
    esac
    [[ "$nic_role" == "dept" ]] && NIC_ROLE_DEPT_IDX=$(( nic_num - 1 ))
    [[ "$nic_role" == "corp" ]] && NIC_ROLE_CORP_IDX=$(( nic_num - 1 ))

    local method_opts=("Bridge to onboard NIC (shared, no MAC isolation)")
    local available_usb=()
    for u in "${FREE_USB_NICS[@]:-}"; do
      local already=false
      for c in "${SESSION_CLAIMED_USB[@]:-}"; do
        [[ "$c" == "$u" ]] && already=true && break
      done
      $already || available_usb+=("$u")
    done
    [[ ${#available_usb[@]} -gt 0 ]] && \
      method_opts+=("USB NIC passthrough (exclusive, stable MAC)")

    local method_idx=0
    pick_menu method_idx "How should vNIC${nic_num} connect?" "${method_opts[@]}"

    local nic_type="" bridge_name="" usb_iface="" nic_mac="" ip_cidr="" gw="" dns=""

    if [[ $method_idx -eq 0 ]]; then
      nic_type="bridge"
      local bridge_opts=()
      for b in "${EXISTING_BRIDGES[@]:-}"; do bridge_opts+=("$b (existing)"); done
      bridge_opts+=("Create a new bridge")

      local b_idx=0
      pick_menu b_idx "Which bridge?" "${bridge_opts[@]}"

      local existing_count=${#EXISTING_BRIDGES[@]}
      if (( b_idx < existing_count )); then
        bridge_name=${EXISTING_BRIDGES[$b_idx]}
      else
        local next_num=0
        while ip link show "vmbr${next_num}" &>/dev/null 2>&1; do
          next_num=$(( next_num + 1 ))
        done
        prompt_default bridge_name "New bridge name" "vmbr${next_num}"
        echo "Available physical interfaces:"
        for iface in "${ALL_IFACES[@]}"; do
          echo "  ${iface}  MAC=$(iface_mac "$iface")"
        done
        local onboard_iface
        prompt_required onboard_iface "Physical NIC to attach to ${bridge_name}"
        BRIDGE_IFACE_MAP["$bridge_name"]="$onboard_iface"
        EXISTING_BRIDGES+=("$bridge_name")
      fi
      nic_mac="virtio-generated"

    else
      nic_type="usb"
      if [[ ${#available_usb[@]} -eq 1 ]]; then
        usb_iface=${available_usb[0]}
        nic_mac=${USB_NIC_MAC[$usb_iface]:-unknown}
        info "Using only available free USB NIC: ${usb_iface}  MAC=${nic_mac}  bus=${USB_NIC_BUS_PATH[$usb_iface]:-unknown}"
      else
        local usb_opts=()
        for u in "${available_usb[@]}"; do
          local mac=${USB_NIC_MAC[$u]:-unknown}
          local bp=${USB_NIC_BUS_PATH[$u]:-unknown}
          usb_opts+=("${u}  MAC=${mac}  bus=${bp}  (${USB_NIC_VENDOR_PRODUCT[$u]})")
        done
        local usb_idx=0
        pick_menu usb_idx "Which USB NIC?" "${usb_opts[@]}"
        usb_iface=${available_usb[$usb_idx]}
        nic_mac=${USB_NIC_MAC[$usb_iface]:-unknown}
      fi
      SESSION_CLAIMED_USB+=("$usb_iface")
      ok "Reserved ${usb_iface}  MAC=${nic_mac}  bus=${USB_NIC_BUS_PATH[$usb_iface]:-unknown}  for ${vm_label} vNIC${nic_num}"
    fi

    prompt_ip_cidr ip_cidr "${net_label}"

    gw=""
    if confirm "Is this the default-route NIC for ${vm_label}?"; then
      prompt_required gw "Default gateway"
    fi
    prompt_default dns "DNS server" "8.8.8.8"

    VM_NICS_TYPE+=("$nic_type"); VM_NICS_LABEL+=("$net_label")
    VM_NICS_BRIDGE+=("$bridge_name"); VM_NICS_USB+=("$usb_iface")
    VM_NICS_MAC+=("$nic_mac")
    VM_NICS_IP+=("$ip_cidr"); VM_NICS_GW+=("$gw"); VM_NICS_DNS+=("$dns")
    VM_NICS_ROLE+=("$nic_role")

    nic_num=$(( nic_num + 1 ))
    confirm "Add another NIC to ${vm_label}?" || break
  done
}

# =============================================================================
# Collect NIC config — Ansible first, then Server
# =============================================================================
if $CREATE_ANSIBLE; then
  header "Ansible Controller VM — NIC Configuration"
  configure_vm_nics "Ansible VM"
  ANSIBLE_NICS_TYPE=("${VM_NICS_TYPE[@]}");   ANSIBLE_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  ANSIBLE_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}"); ANSIBLE_NICS_USB=("${VM_NICS_USB[@]}")
  ANSIBLE_NICS_MAC=("${VM_NICS_MAC[@]}")
  ANSIBLE_NICS_IP=("${VM_NICS_IP[@]}");         ANSIBLE_NICS_GW=("${VM_NICS_GW[@]}")
  ANSIBLE_NICS_DNS=("${VM_NICS_DNS[@]}")
  ANSIBLE_NICS_ROLE=("${VM_NICS_ROLE[@]}")
fi

if $CREATE_SERVER; then
  header "RideStatus Server VM — NIC Configuration"
  configure_vm_nics "Server VM"
  SERVER_NICS_TYPE=("${VM_NICS_TYPE[@]}");   SERVER_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  SERVER_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}"); SERVER_NICS_USB=("${VM_NICS_USB[@]}")
  SERVER_NICS_MAC=("${VM_NICS_MAC[@]}")
  SERVER_NICS_IP=("${VM_NICS_IP[@]}");         SERVER_NICS_GW=("${VM_NICS_GW[@]}")
  SERVER_NICS_DNS=("${VM_NICS_DNS[@]}")
  SERVER_NICS_ROLE=("${VM_NICS_ROLE[@]}")
  SERVER_DEPT_NIC_IDX=$NIC_ROLE_DEPT_IDX
  SERVER_CORP_NIC_IDX=$NIC_ROLE_CORP_IDX
fi

# =============================================================================
# VM IDs — Ansible first
# =============================================================================
header "VM IDs"

next_free_vmid() {
  local id=100
  while pvesh get "/nodes/${PROXMOX_NODE}/qemu/${id}/status" &>/dev/null 2>&1; do
    id=$(( id + 1 ))
  done
  echo $id
}

pick_vmid() {
  local -n _vmid=$1; local label=$2
  local suggested; suggested=$(next_free_vmid)
  while true; do
    prompt_default _vmid "VM ID for ${label}" "$suggested"
    if pvesh get "/nodes/${PROXMOX_NODE}/qemu/${_vmid}/status" &>/dev/null 2>&1; then
      warn "VM ID ${_vmid} is already in use."
      suggested=$(next_free_vmid); warn "Next available: ${suggested}"
    else
      break
    fi
  done
}

if $CREATE_ANSIBLE; then pick_vmid ANSIBLE_VMID "Ansible Controller"; fi
if $CREATE_SERVER;  then pick_vmid SERVER_VMID  "RideStatus Server"; fi

# =============================================================================
# VM resources and hostnames — Ansible first, then Server
# =============================================================================
header "VM Resources"

if $CREATE_ANSIBLE; then
  prompt_default ANSIBLE_RAM   "Ansible VM RAM (GB)"  "2"
  prompt_default ANSIBLE_CORES "Ansible VM CPU cores" "2"
  prompt_default ANSIBLE_DISK  "Ansible VM disk (GB)" "20"
  prompt_default ANSIBLE_HOST  "Ansible VM hostname"  "ridestatus-ansible"
fi

if $CREATE_SERVER; then
  prompt_default SERVER_RAM   "Server VM RAM (GB)"  "4"
  prompt_default SERVER_CORES "Server VM CPU cores" "2"
  # 64GB default: PostgreSQL stores ride history for all rides (potentially
  # 50+ edge nodes pushing at 3s intervals indefinitely). 32GB is too tight
  # for a multi-season deployment once WAL, indexes, and logs accumulate.
  prompt_default SERVER_DISK  "Server VM disk (GB)" "64"
  prompt_default SERVER_HOST  "Server VM hostname"  "ridestatus-server"
fi

# =============================================================================
# Admin SSH key
# =============================================================================
header "Admin SSH Key"

ADMIN_GENERATED=false

echo -e "${BOLD}Paste your SSH public key below, or press Enter to generate one automatically.${RESET}"
echo -e "(A generated key will be saved to ${ADMIN_KEY_PATH} on this Proxmox host)"
read -rp "$(echo -e "${BOLD}SSH public key${RESET} [press Enter to generate]: ")" ADMIN_SSH_PUBKEY

if [[ -z "$ADMIN_SSH_PUBKEY" ]]; then
  if [[ -f "${ADMIN_KEY_PATH}.pub" ]]; then
    ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
    ok "Using existing admin key at ${ADMIN_KEY_PATH}"
  else
    ssh-keygen -t ed25519 -f "$ADMIN_KEY_PATH" -N "" -C "ridestatus-admin" -q
    ADMIN_SSH_PUBKEY=$(cat "${ADMIN_KEY_PATH}.pub")
    ADMIN_GENERATED=true
    ok "Admin keypair generated and saved to ${ADMIN_KEY_PATH}"
  fi
fi

# =============================================================================
# Summary
# =============================================================================
header "Summary — Review Before Proceeding"

print_vm_summary() {
  local label=$1 vmid=$2 hostname=$3 ram=$4 cores=$5 disk=$6
  local -n _nt=$7 _nl=$8 _nb=$9 _nu=${10} _nm=${11} _ni=${12} _ng=${13} _nr=${14}
  echo -e "  ${BOLD}${label}${RESET}"
  echo "    VM ID: ${vmid}  Hostname: ${hostname}  RAM: ${ram}GB  Cores: ${cores}  Disk: ${disk}GB"
  for i in "${!_nt[@]}"; do
    local conn=""
    if [[ "${_nt[$i]}" == "bridge" ]]; then
      conn="bridge=${_nb[$i]}  MAC=${_nm[$i]}"
    else
      local bp=${USB_NIC_BUS_PATH[${_nu[$i]}]:-unknown}
      conn="USB passthrough=${_nu[$i]}  MAC=${_nm[$i]}  bus=${bp}"
    fi
    local gw_str=""; [[ -n "${_ng[$i]:-}" ]] && gw_str="  GW=${_ng[$i]}"
    local role_str=""
    case "${_nr[$i]:-other}" in
      dept)  role_str="  [DEPT/RideStatus NIC]" ;;
      corp)  role_str="  [Corporate NIC]" ;;
    esac
    echo "    vNIC$((i+1)): ${_nl[$i]}  IP=${_ni[$i]}${gw_str}  [${conn}]${role_str}"
  done
}

echo ""
$CREATE_ANSIBLE && print_vm_summary "Ansible Controller" "$ANSIBLE_VMID" "$ANSIBLE_HOST" \
  "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
  ANSIBLE_NICS_TYPE ANSIBLE_NICS_LABEL ANSIBLE_NICS_BRIDGE \
  ANSIBLE_NICS_USB  ANSIBLE_NICS_MAC   ANSIBLE_NICS_IP ANSIBLE_NICS_GW ANSIBLE_NICS_ROLE
echo ""
$CREATE_SERVER  && print_vm_summary "RideStatus Server" "$SERVER_VMID" "$SERVER_HOST" \
  "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
  SERVER_NICS_TYPE SERVER_NICS_LABEL SERVER_NICS_BRIDGE \
  SERVER_NICS_USB  SERVER_NICS_MAC   SERVER_NICS_IP SERVER_NICS_GW SERVER_NICS_ROLE

echo ""
info "Storage: OS disk → ${DISK_STORAGE}  |  Cloud-init → ${CI_STORAGE}"
if $ADMIN_GENERATED; then
  info "Admin SSH key: ${ADMIN_KEY_PATH} (private) — copy to your PC after deployment"
  info "              ${ADMIN_KEY_PATH}.pub (public)"
else
  info "Admin SSH key: provided by operator"
fi

echo ""
warn "This will create VMs and modify Proxmox network configuration."
read -rp "$(echo -e "${BOLD}Type 'yes' to proceed: ${RESET}")" final_confirm
[[ "$final_confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# =============================================================================
# Helpers: bridge, image
# =============================================================================
ensure_bridge() {
  local bridge=$1
  if ! ip link show "$bridge" &>/dev/null 2>&1; then
    local phys=${BRIDGE_IFACE_MAP[$bridge]:-none}
    info "Creating bridge ${bridge} (attached to ${phys})"
    { echo "auto ${bridge}"
      echo "iface ${bridge} inet manual"
      echo "  bridge_ports ${phys}"
      echo "  bridge_stp off"
      echo "  bridge_fd 0"
    } > "/etc/network/interfaces.d/${bridge}"
    ifup "$bridge" 2>/dev/null || true
    ok "Bridge ${bridge} created"
  else
    info "Bridge ${bridge} already exists — skipping"
  fi
}

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMG_PATH="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"

ensure_ubuntu_image() {
  if [[ -f "$UBUNTU_IMG_PATH" ]]; then
    info "Ubuntu 24.04 cloud image already cached"
  else
    info "Downloading Ubuntu 24.04 cloud image..."
    mkdir -p "$(dirname "$UBUNTU_IMG_PATH")"
    wget -q --show-progress -O "$UBUNTU_IMG_PATH" "$UBUNTU_IMG_URL" \
      || die "Failed to download Ubuntu image"
    ok "Image downloaded"
  fi
}

# =============================================================================
# Helper: write cloud-init user-data snippet for a VM
#
# When --cicustom user= is set, Proxmox's --ciuser and --sshkeys are completely
# ignored by cloud-init — the snippet IS the entire user-data section. So this
# snippet must handle user creation, SSH authorized_keys, sudo, AND package
# installation. Network config (--ipconfig, --nameserver) is unaffected because
# it lives in a separate Proxmox-managed network-data section.
# =============================================================================
write_userdata_snippet() {
  local vmid=$1 deploy_key=$2 admin_key=$3
  local snippet_file="${SNIPPET_DIR}/ridestatus-userdata-${vmid}.yaml"

  cat > "$snippet_file" <<YAML
#cloud-config
users:
  - name: ridestatus
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${deploy_key}
      - ${admin_key}

packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
YAML

  echo "$snippet_file"
}

# =============================================================================
# Helper: create and configure a VM
#
# IMPORTANT: All qm set calls must complete BEFORE qm cloudinit update, which
# rebuilds the cloud-init ISO from the current VM config. The VM is only
# started after the ISO is up to date.
#
# NOTE: --ciuser and --sshkeys are NOT set here because --cicustom user= makes
# them irrelevant. The snippet handles user creation and key injection instead.
#
# NOTE: All counter increments use x=$(( x+1 )) rather than (( x++ )) because
# under set -e, (( expr )) exits with code 1 when the expression evaluates to
# zero — which happens on the first increment when the counter starts at 0.
# =============================================================================
create_vm() {
  local vmid=$1 hostname=$2 ram_gb=$3 cores=$4 disk_gb=$5
  local -n cv_type=$6 cv_bridge=$7 cv_usb=$8 cv_ip=$9 cv_gw=${10} cv_dns=${11}

  info "Creating VM ${vmid} (${hostname})..."
  local ram_mb=$(( ram_gb * 1024 ))

  qm create "$vmid" --name "$hostname" --memory "$ram_mb" --cores "$cores" \
    --cpu cputype=host --ostype l26 --agent enabled=1 --serial0 socket --vga serial0

  local img_copy="/tmp/ridestatus-vm${vmid}.img"
  cp "$UBUNTU_IMG_PATH" "$img_copy"
  qm importdisk "$vmid" "$img_copy" "$DISK_STORAGE" --format qcow2
  rm -f "$img_copy"

  qm set "$vmid" --scsihw virtio-scsi-pci \
    --scsi0 "${DISK_STORAGE}:vm-${vmid}-disk-0,discard=on" --boot order=scsi0
  qm resize "$vmid" scsi0 "${disk_gb}G"

  # Attach NICs
  local bridge_nic_idx=0 usb_slot=0
  for i in "${!cv_type[@]}"; do
    if [[ "${cv_type[$i]}" == "bridge" ]]; then
      qm set "$vmid" --net${bridge_nic_idx} "virtio,bridge=${cv_bridge[$i]}"
      bridge_nic_idx=$(( bridge_nic_idx + 1 ))
    else
      local host_iface=${cv_usb[$i]}
      local bp=${USB_NIC_BUS_PATH[$host_iface]:-}
      if [[ -z "$bp" ]]; then
        local vp=${USB_NIC_VENDOR_PRODUCT[$host_iface]:-}
        [[ -z "$vp" ]] && die "Cannot find bus path or vendor:product for ${host_iface}"
        warn "Bus path unavailable for ${host_iface} — falling back to host=${vp} (may be ambiguous)"
        qm set "$vmid" --usb${usb_slot} "host=${vp}"
      else
        info "Assigning USB NIC ${host_iface} (MAC ${USB_NIC_MAC[$host_iface]:-unknown}) via host=${bp}"
        qm set "$vmid" --usb${usb_slot} "host=${bp}"
      fi
      usb_slot=$(( usb_slot + 1 ))
    fi
  done

  # Cloud-init drive
  qm set "$vmid" --ide2 "${CI_STORAGE}:cloudinit"

  # Network config (unaffected by cicustom user=)
  local ipconfig_idx=0
  for i in "${!cv_type[@]}"; do
    [[ "${cv_type[$i]}" != "bridge" ]] && continue
    local ip="${cv_ip[$i]}"
    local gw_part=""
    [[ -n "${cv_gw[$i]:-}" ]] && gw_part=",gw=${cv_gw[$i]}"
    qm set "$vmid" --ipconfig${ipconfig_idx} "ip=${ip}${gw_part}"
    ipconfig_idx=$(( ipconfig_idx + 1 ))
  done

  qm set "$vmid" --nameserver "${cv_dns[0]:-8.8.8.8}"
  qm set "$vmid" --ciupgrade 0

  # Write full user-data snippet (user + keys + packages).
  # DO NOT also set --ciuser/--sshkeys — they are ignored when cicustom user= is active.
  local snippet_file
  snippet_file=$(write_userdata_snippet "$vmid" "$DEPLOY_PUBKEY_CONTENT" "$ADMIN_SSH_PUBKEY")
  qm set "$vmid" --cicustom "user=${CI_STORAGE}:snippets/$(basename "$snippet_file")"
  info "Cloud-init user-data snippet written: $(basename "$snippet_file")"

  # Rebuild the cloud-init ISO from current config BEFORE starting the VM.
  info "Regenerating cloud-init ISO for VM ${vmid}..."
  qm cloudinit update "$vmid"
  ok "Cloud-init ISO updated for VM ${vmid}"

  ok "VM ${vmid} configured"
}

# =============================================================================
# Helper: wait for guest agent
# =============================================================================
wait_for_guest_agent() {
  local vmid=$1 max_wait=${2:-900} elapsed=0
  info "Waiting for guest agent on VM ${vmid} (up to ${max_wait}s — first boot may take 10+ min)..."
  while (( elapsed < max_wait )); do
    qm guest cmd "$vmid" ping &>/dev/null 2>&1 && { ok "Guest agent ready on VM ${vmid}"; return 0; }
    sleep 10
    elapsed=$(( elapsed + 10 ))
    if (( elapsed % 60 == 0 )); then
      echo " ${elapsed}s"
    else
      echo -n "."
    fi
  done
  echo ""; die "Timed out waiting for guest agent on VM ${vmid}"
}

# =============================================================================
# Helper: fix USB NIC names via guest agent
# =============================================================================
fix_usb_nic_names() {
  local vmid=$1
  local -n fnn_type=$2 fnn_usb=$3 fnn_ip=$4

  local has_usb=false
  for t in "${fnn_type[@]}"; do [[ "$t" == "usb" ]] && has_usb=true && break; done
  $has_usb || return 0

  info "Querying guest agent for NIC names in VM ${vmid}..."
  local ga_json
  ga_json=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null || true)
  [[ -z "$ga_json" ]] && { warn "No NIC data from guest agent"; return 0; }

  declare -A GA_MAC_TO_NAME=()
  while IFS= read -r line; do
    local name mac
    name=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || true)
    mac=$(echo  "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hardware-address','').lower())" 2>/dev/null || true)
    [[ -n "$name" && -n "$mac" ]] && GA_MAC_TO_NAME["$mac"]="$name"
  done < <(echo "$ga_json" | python3 -c \
    "import sys,json; [print(json.dumps(x)) for x in json.load(sys.stdin).get('result',[])]" \
    2>/dev/null || true)

  [[ ${#GA_MAC_TO_NAME[@]} -eq 0 ]] && { warn "Guest agent returned no NIC data"; return 0; }

  local usb_slot=0 needs_fix=false
  declare -A USB_REAL_NAME=()

  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" != "usb" ]] && continue
    local host_iface=${fnn_usb[$i]}
    local host_mac; host_mac=$(iface_mac "$host_iface" | tr '[:upper:]' '[:lower:]')
    local real_name=${GA_MAC_TO_NAME[$host_mac]:-}
    local placeholder="usb-placeholder-${usb_slot}"

    if [[ -z "$real_name" ]]; then
      warn "No guest NIC matched MAC ${host_mac} — ${placeholder} may need manual fix"
    elif [[ "$real_name" != "$placeholder" ]]; then
      info "USB NIC ${host_iface} (MAC ${host_mac}) is '${real_name}' inside VM"
      USB_REAL_NAME["$placeholder"]="$real_name"
      needs_fix=true
    fi
    usb_slot=$(( usb_slot + 1 ))
  done

  $needs_fix || { ok "All NIC names correct — no netplan patch needed"; return 0; }

  local ssh_ip=""
  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" == "bridge" ]] && { ssh_ip="${fnn_ip[$i]%%/*}"; break; }
  done
  [[ -z "$ssh_ip" ]] && ssh_ip="${fnn_ip[0]%%/*}"

  local sed_args=()
  for placeholder in "${!USB_REAL_NAME[@]}"; do
    sed_args+=(-e "s/${placeholder}/${USB_REAL_NAME[$placeholder]}/g")
  done

  deploy_ssh "$ssh_ip" "
    set -e
    f=\$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    [[ -z \"\$f\" ]] && { echo 'No netplan file'; exit 1; }
    sudo sed -i ${sed_args[*]} \"\$f\"
    sudo netplan apply
  " && ok "Netplan patched in VM ${vmid}" \
    || warn "Netplan patch failed — check USB NIC names manually"
}

# =============================================================================
# Helper: first IP (for SSH)
# =============================================================================
first_ip() { local -n _fi=$1; echo "${_fi[0]%%/*}"; }

# =============================================================================
# Helper: wait for SSH
# =============================================================================
wait_for_ssh() {
  local ip=$1 max_wait=300 elapsed=0
  info "Waiting for SSH on ${ip}..."
  while (( elapsed < max_wait )); do
    deploy_ssh "$ip" 'exit 0' &>/dev/null && { ok "SSH ready on ${ip}"; return 0; }
    sleep 5
    elapsed=$(( elapsed + 5 ))
    echo -n "."
  done
  echo ""; die "Timed out waiting for SSH on ${ip}"
}

# =============================================================================
# Helper: run bootstrap script in a VM
# =============================================================================
BOOTSTRAP_BASE_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap"
ANSIBLE_KEY_SERVER_PORT=9876

run_bootstrap() {
  local ip=$1 script=$2 extra_env=${3:-}
  info "Running ${script} on ${ip}..."
  local env_prefix=""
  [[ -n "$extra_env" ]] && env_prefix="export ${extra_env} && "
  # -t allocates a pseudo-TTY so server.sh can use /dev/tty for interactive
  # prompts (Park Configuration). Double -t inside deploy_ssh forces TTY
  # allocation even when deploy.sh has no TTY (bash <(curl ...)).
  # Cache-bust the URL with a timestamp so GitHub CDN always serves the latest
  # version of the bootstrap script. Without this, a stale CDN cache can serve
  # an old script version even after a commit (as seen in Session 12 run).
  deploy_ssh -t "$ip" \
    "${env_prefix}curl -fsSL -H 'Cache-Control: no-cache' '${BOOTSTRAP_BASE_URL}/${script}?'\$(date +%s) | sudo -E bash" || {
    echo ""
    err "Bootstrap failed for ${script} on ${ip}."
    err "To retry: ssh ridestatus@${ip}"
    err "  curl -fsSL -H 'Cache-Control: no-cache' '${BOOTSTRAP_BASE_URL}/${script}?'\$(date +%s) | sudo bash"
    return 1
  }
  ok "${script} completed on ${ip}"
}

# =============================================================================
# EXECUTE
# =============================================================================

header "Creating Bridges"
for bridge in "${!BRIDGE_IFACE_MAP[@]}"; do ensure_bridge "$bridge"; done

ensure_ubuntu_image

# Create Ansible VM first (it needs to be up and running its key server
# before server.sh runs, so the earlier it starts booting the better)
if $CREATE_ANSIBLE; then
  header "Creating Ansible Controller VM (${ANSIBLE_VMID})"
  create_vm "$ANSIBLE_VMID" "$ANSIBLE_HOST" "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
    ANSIBLE_NICS_TYPE ANSIBLE_NICS_BRIDGE ANSIBLE_NICS_USB \
    ANSIBLE_NICS_IP   ANSIBLE_NICS_GW     ANSIBLE_NICS_DNS
  qm start "$ANSIBLE_VMID"
  purge_known_host "$(first_ip ANSIBLE_NICS_IP)"
  ok "VM ${ANSIBLE_VMID} started"
fi

if $CREATE_SERVER; then
  header "Creating RideStatus Server VM (${SERVER_VMID})"
  create_vm "$SERVER_VMID" "$SERVER_HOST" "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
    SERVER_NICS_TYPE SERVER_NICS_BRIDGE SERVER_NICS_USB \
    SERVER_NICS_IP   SERVER_NICS_GW     SERVER_NICS_DNS
  qm start "$SERVER_VMID"
  purge_known_host "$(first_ip SERVER_NICS_IP)"
  ok "VM ${SERVER_VMID} started"
fi

# ---- Bootstrap Ansible VM first (generates key + starts key server) --------
if $CREATE_ANSIBLE; then
  wait_for_guest_agent "$ANSIBLE_VMID"
  fix_usb_nic_names "$ANSIBLE_VMID" ANSIBLE_NICS_TYPE ANSIBLE_NICS_USB ANSIBLE_NICS_IP
  ANSIBLE_IP=$(first_ip ANSIBLE_NICS_IP)
  wait_for_ssh "$ANSIBLE_IP"
  info "Running ansible.sh on ${ANSIBLE_IP} (key server will stay up for server.sh)..."
  deploy_ssh "$ANSIBLE_IP" \
    "curl -fsSL -H 'Cache-Control: no-cache' '${BOOTSTRAP_BASE_URL}/ansible.sh?'\$(date +%s) | sudo bash" &
  ANSIBLE_BOOTSTRAP_PID=$!
  info "Waiting for Ansible key server to start (30s)..."
  sleep 30
fi

# ---- Bootstrap Server VM ---------------------------------------------------
if $CREATE_SERVER; then
  wait_for_guest_agent "$SERVER_VMID"
  fix_usb_nic_names "$SERVER_VMID" SERVER_NICS_TYPE SERVER_NICS_USB SERVER_NICS_IP
  SERVER_IP=$(first_ip SERVER_NICS_IP)
  wait_for_ssh "$SERVER_IP"

  # Build env string for server.sh — pass the key server URL directly so
  # server.sh curls the key itself (avoids multi-layer shell quoting issues).
  # Also pass ANSIBLE_VM_HOST and NIC role hints for .env pre-population.
  SERVER_BOOTSTRAP_ENV=""

  if $CREATE_ANSIBLE; then
    ANSIBLE_IP=$(first_ip ANSIBLE_NICS_IP)
    ANSIBLE_KEY_URL="http://${ANSIBLE_IP}:${ANSIBLE_KEY_SERVER_PORT}/ansible_ridestatus.pub"
    ok "Will pass Ansible key URL to server.sh: ${ANSIBLE_KEY_URL}"
    SERVER_BOOTSTRAP_ENV="ANSIBLE_KEY_URL=${ANSIBLE_KEY_URL}"
    SERVER_BOOTSTRAP_ENV+=" ANSIBLE_VM_HOST=${ANSIBLE_IP}"
  else
    info "Ansible VM is on a separate host."
    info "server.sh will ask for the Ansible key server URL when it runs."
  fi

  # Pass NIC role hints if the tech designated dept/corp NICs.
  # These are net index hints (net0, net1, ...) that server.sh uses to
  # resolve to actual kernel interface names (ens18, ens19, etc.)
  if (( SERVER_DEPT_NIC_IDX >= 0 )); then
    SERVER_BOOTSTRAP_ENV+=" RS_DEPT_NIC_HINT=net${SERVER_DEPT_NIC_IDX}"
  fi
  if (( SERVER_CORP_NIC_IDX >= 0 )); then
    SERVER_BOOTSTRAP_ENV+=" RS_CORP_NIC_HINT=net${SERVER_CORP_NIC_IDX}"
  fi

  run_bootstrap "$SERVER_IP" "server.sh" "$SERVER_BOOTSTRAP_ENV" || true
fi

# ---- Wait for Ansible bootstrap to finish ----------------------------------
if $CREATE_ANSIBLE && [[ -n "${ANSIBLE_BOOTSTRAP_PID:-}" ]]; then
  info "Waiting for ansible.sh to complete..."
  wait "$ANSIBLE_BOOTSTRAP_PID" 2>/dev/null && ok "ansible.sh complete" \
    || warn "ansible.sh may have encountered errors — check logs on ${ANSIBLE_IP}"
fi

# =============================================================================
# Done
# =============================================================================
header "Deployment Complete"

$CREATE_ANSIBLE && ok "Ansible Controller VM ${ANSIBLE_VMID} (${ANSIBLE_HOST}) — $(first_ip ANSIBLE_NICS_IP)"
$CREATE_SERVER  && ok "RideStatus Server VM ${SERVER_VMID}  (${SERVER_HOST})  — $(first_ip SERVER_NICS_IP)"

echo ""
info "Next steps:"
info "  1. Verify VMs are accessible in the Proxmox web UI"
info "  2. SSH to each VM as ridestatus@<ip> using your admin key"
info "  3. Run bootstrap/edge-init.sh on each ride edge node"
if $ADMIN_GENERATED; then
  echo ""
  warn "*** IMPORTANT: Copy your admin SSH private key off this Proxmox host ***"
  warn "    Private key : ${ADMIN_KEY_PATH}"
  warn "    Public key  : ${ADMIN_KEY_PATH}.pub"
  warn "    Use WinSCP or similar to download ${ADMIN_KEY_PATH} to your PC."
  warn "    In PuTTY/WinSCP, convert it with PuTTYgen if needed (File > Load, Save private key as .ppk)"
fi
echo ""
