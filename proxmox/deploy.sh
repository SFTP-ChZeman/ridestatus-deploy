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
#   exclusively for bootstrap SSH connections, then deletes it on exit.
#
# USB NIC naming:
#   After each VM boots, the QEMU guest agent is queried for real NIC names.
#   Any USB passthrough NIC netplan placeholders are patched in-place.
#
# Ansible public key handoff:
#   When BOTH VMs are on this host, deploy.sh fetches the Ansible public key
#   automatically from ansible.sh's one-shot key server and passes it to
#   server.sh via the ANSIBLE_PUBKEY env var — no copy-paste needed.
#   When only one VM is on this host, server.sh prompts for the key URL
#   (which ansible.sh printed) and fetches it itself.
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

# =============================================================================
# Preflight
# =============================================================================
header "RideStatus Proxmox Deploy"

[[ $EUID -eq 0 ]] || die "This script must be run as root."
command -v pvesh    >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox host?"
command -v qm       >/dev/null 2>&1 || die "qm not found — is this a Proxmox host?"
command -v lsusb    >/dev/null 2>&1 || die "lsusb not found (apt install usbutils)"
command -v ssh      >/dev/null 2>&1 || die "ssh not found"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
command -v python3  >/dev/null 2>&1 || die "python3 not found"
command -v curl     >/dev/null 2>&1 || die "curl not found"

PROXMOX_NODE=$(hostname)
info "Proxmox node: ${PROXMOX_NODE}"

# =============================================================================
# Temporary deploy keypair
# =============================================================================
DEPLOY_KEY_DIR=$(mktemp -d /tmp/ridestatus-deploy-XXXXXX)
DEPLOY_KEY="${DEPLOY_KEY_DIR}/id_ed25519"
DEPLOY_PUBKEY="${DEPLOY_KEY}.pub"

ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "ridestatus-deploy-temp" -q
DEPLOY_PUBKEY_CONTENT=$(cat "$DEPLOY_PUBKEY")
ok "Temporary deploy keypair generated (deleted on exit)"

cleanup() {
  rm -rf "$DEPLOY_KEY_DIR"
  rm -f /var/lib/vz/snippets/vm-*-user.yaml \
        /var/lib/vz/snippets/vm-*-net.yaml 2>/dev/null || true
}
trap cleanup EXIT

deploy_ssh() {
  local ip=$1; shift
  ssh -i "$DEPLOY_KEY" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "ridestatus@${ip}" "$@"
}

# =============================================================================
# Detect physical interfaces and bridges
# =============================================================================
header "Detecting Network Interfaces"

mapfile -t ALL_IFACES < <(
  ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' \
  | grep -Ev '^(vmbr|tap|veth|fwbr|fwpr)'
)

mapfile -t EXISTING_BRIDGES < <(
  brctl show 2>/dev/null | awk 'NR>1 && $1!="" {print $1}' || true
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

# =============================================================================
# Enumerate USB NICs — free list keyed by USB bus path
#
# USB NICs are identified by their sysfs bus path (e.g. "1-1.2"), not by
# vendor:product ID. This ensures two identical USB NICs (same make/model)
# are treated as distinct devices and only the actually-claimed one is
# excluded from the free list.
#
# Proxmox stores USB passthrough in VM config as either:
#   host=<vendorid>:<productid>   — ambiguous when multiple identical NICs exist
#   host=<bus>-<port>             — unambiguous, preferred
#
# We read both forms from existing VM configs and resolve vendor:product
# entries back to bus paths so the claimed set is always bus-path keyed.
# =============================================================================
header "USB NIC Detection"

# Maps: iface -> vendor:product, iface -> bus path (e.g. "1-1.2"), iface -> MAC
declare -A USB_NIC_VENDOR_PRODUCT   # iface -> "vvvv:pppp"
declare -A USB_NIC_BUS_PATH         # iface -> "bus-port" (e.g. "1-1.2")
declare -A USB_NIC_MAC              # iface -> MAC address

# Set of bus paths claimed by existing VMs
declare -A USB_BUS_PATH_CLAIMED_BY  # bus_path -> vmid

declare -a FREE_USB_NICS=()

for iface in "${ALL_IFACES[@]}"; do
  syspath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
  [[ -z "$syspath" ]] && continue
  echo "$syspath" | grep -q '/usb' || continue

  # Walk up sysfs to find the USB interface directory (contains idVendor/idProduct)
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

  # Extract bus path from sysfs path.
  # sysfs path looks like: /sys/bus/usb/devices/1-1.2/...
  # The bus path component is the segment after /devices/ that matches N-N[.N]*
  bus_path=$(echo "$syspath" | grep -oP '(?<=/devices/)[\d]+-[\d.]+(?=/)' | head -1 || true)
  [[ -n "$bus_path" ]] && USB_NIC_BUS_PATH["$iface"]="$bus_path"
done

# Build claimed set from existing VMs
if [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -gt 0 ]]; then
  mapfile -t ALL_VMIDS < <(
    pvesh get "/nodes/${PROXMOX_NODE}/qemu" --output-format json 2>/dev/null \
    | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' || true
  )

  # Build a lookup: vendor:product -> list of known bus paths (from this host's NICs)
  # Used to resolve vp-style VM config entries back to bus paths.
  declare -A VP_TO_BUS_PATHS  # "vvvv:pppp" -> space-separated bus paths
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
        # Already a bus path — mark directly
        USB_BUS_PATH_CLAIMED_BY["$raw"]="$vmid"
      elif echo "$raw" | grep -qP '^[0-9a-f]{4}:[0-9a-f]{4}$'; then
        # vendor:product form — resolve to bus paths on this host
        # If only one NIC on this host has this vp, we know exactly which one.
        # If multiple NICs share the vp, mark all of them as claimed to be safe
        # (operator should use bus-path passthrough for identical NICs anyway).
        known_paths=${VP_TO_BUS_PATHS[$raw]:-}
        for bp in $known_paths; do
          USB_BUS_PATH_CLAIMED_BY["$bp"]="$vmid"
        done
      fi
    done < <(echo "$vm_config" | grep -o '"usb[0-9]*":"[^"]*"' || true)
  done
fi

# Build free list: NICs whose bus path is not in the claimed set
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
  "RideStatus Server only" \
  "Ansible Controller only" \
  "Both"

case $pick_idx in
  0) CREATE_SERVER=true ;;
  1) CREATE_ANSIBLE=true ;;
  2) CREATE_SERVER=true; CREATE_ANSIBLE=true ;;
esac

$CREATE_SERVER  && info "Will create: RideStatus Server VM"
$CREATE_ANSIBLE && info "Will create: Ansible Controller VM"

declare -a SESSION_CLAIMED_USB=()
declare -A BRIDGE_IFACE_MAP

# =============================================================================
# NIC configuration helper
# =============================================================================
configure_vm_nics() {
  local vm_label=$1
  VM_NICS_TYPE=(); VM_NICS_LABEL=(); VM_NICS_BRIDGE=()
  VM_NICS_USB=();  VM_NICS_MAC=();   VM_NICS_IP=(); VM_NICS_GW=(); VM_NICS_DNS=()

  local nic_num=1
  while true; do
    echo ""
    echo -e "${BOLD}--- ${vm_label}: vNIC${nic_num} ---${RESET}"

    local net_label
    prompt_required net_label \
      "What network does vNIC${nic_num} connect to? (e.g. Department, Corporate VLAN)"

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

      local existing_count=${#EXISTING_BRIDGES[@]:-0}
      if (( b_idx < existing_count )); then
        bridge_name=${EXISTING_BRIDGES[$b_idx]}
      else
        local next_num=0
        while ip link show "vmbr${next_num}" &>/dev/null 2>&1; do (( next_num++ )); done
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
      # MAC not meaningful for bridged NICs (VM gets a virtio-generated MAC)
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

    prompt_required ip_cidr \
      "Static IP and prefix for ${net_label} (e.g. 10.15.140.101/25)"

    gw=""
    if confirm "Is this the default-route NIC for ${vm_label}?"; then
      prompt_required gw "Default gateway"
    fi
    prompt_default dns "DNS server" "8.8.8.8"

    VM_NICS_TYPE+=("$nic_type"); VM_NICS_LABEL+=("$net_label")
    VM_NICS_BRIDGE+=("$bridge_name"); VM_NICS_USB+=("$usb_iface")
    VM_NICS_MAC+=("$nic_mac")
    VM_NICS_IP+=("$ip_cidr"); VM_NICS_GW+=("$gw"); VM_NICS_DNS+=("$dns")

    (( nic_num++ ))
    confirm "Add another NIC to ${vm_label}?" || break
  done
}

# =============================================================================
# Collect NIC config
# =============================================================================
if $CREATE_SERVER; then
  header "RideStatus Server VM — NIC Configuration"
  configure_vm_nics "Server VM"
  SERVER_NICS_TYPE=("${VM_NICS_TYPE[@]}");   SERVER_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  SERVER_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}"); SERVER_NICS_USB=("${VM_NICS_USB[@]}")
  SERVER_NICS_MAC=("${VM_NICS_MAC[@]}")
  SERVER_NICS_IP=("${VM_NICS_IP[@]}");         SERVER_NICS_GW=("${VM_NICS_GW[@]}")
  SERVER_NICS_DNS=("${VM_NICS_DNS[@]}")
fi

if $CREATE_ANSIBLE; then
  header "Ansible Controller VM — NIC Configuration"
  configure_vm_nics "Ansible VM"
  ANSIBLE_NICS_TYPE=("${VM_NICS_TYPE[@]}");   ANSIBLE_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  ANSIBLE_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}"); ANSIBLE_NICS_USB=("${VM_NICS_USB[@]}")
  ANSIBLE_NICS_MAC=("${VM_NICS_MAC[@]}")
  ANSIBLE_NICS_IP=("${VM_NICS_IP[@]}");         ANSIBLE_NICS_GW=("${VM_NICS_GW[@]}")
  ANSIBLE_NICS_DNS=("${VM_NICS_DNS[@]}")
fi

# =============================================================================
# VM IDs
# =============================================================================
header "VM IDs"

next_free_vmid() {
  local id=100
  while pvesh get "/nodes/${PROXMOX_NODE}/qemu/${id}/status" &>/dev/null 2>&1; do
    (( id++ ))
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

if $CREATE_SERVER;  then pick_vmid SERVER_VMID  "RideStatus Server"; fi
if $CREATE_ANSIBLE; then pick_vmid ANSIBLE_VMID "Ansible Controller"; fi

# =============================================================================
# VM resources and hostnames
# =============================================================================
header "VM Resources"

if $CREATE_SERVER; then
  prompt_default SERVER_RAM   "Server VM RAM (GB)"  "4"
  prompt_default SERVER_CORES "Server VM CPU cores" "2"
  prompt_default SERVER_DISK  "Server VM disk (GB)" "32"
  prompt_default SERVER_HOST  "Server VM hostname"  "ridestatus-server"
fi

if $CREATE_ANSIBLE; then
  prompt_default ANSIBLE_RAM   "Ansible VM RAM (GB)"  "2"
  prompt_default ANSIBLE_CORES "Ansible VM CPU cores" "2"
  prompt_default ANSIBLE_DISK  "Ansible VM disk (GB)" "20"
  prompt_default ANSIBLE_HOST  "Ansible VM hostname"  "ridestatus-ansible"
fi

prompt_required ADMIN_SSH_PUBKEY "Admin SSH public key (added to all VMs alongside deploy key)"

# =============================================================================
# Summary
# =============================================================================
header "Summary — Review Before Proceeding"

print_vm_summary() {
  local label=$1 vmid=$2 hostname=$3 ram=$4 cores=$5 disk=$6
  local -n _nt=$7 _nl=$8 _nb=$9 _nu=${10} _nm=${11} _ni=${12} _ng=${13}
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
    echo "    vNIC$((i+1)): ${_nl[$i]}  IP=${_ni[$i]}${gw_str}  [${conn}]"
  done
}

echo ""
$CREATE_SERVER  && print_vm_summary "RideStatus Server" "$SERVER_VMID" "$SERVER_HOST" \
  "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
  SERVER_NICS_TYPE SERVER_NICS_LABEL SERVER_NICS_BRIDGE \
  SERVER_NICS_USB  SERVER_NICS_MAC   SERVER_NICS_IP SERVER_NICS_GW
echo ""
$CREATE_ANSIBLE && print_vm_summary "Ansible Controller" "$ANSIBLE_VMID" "$ANSIBLE_HOST" \
  "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
  ANSIBLE_NICS_TYPE ANSIBLE_NICS_LABEL ANSIBLE_NICS_BRIDGE \
  ANSIBLE_NICS_USB  ANSIBLE_NICS_MAC   ANSIBLE_NICS_IP ANSIBLE_NICS_GW

echo ""
warn "This will create VMs and modify Proxmox network configuration."
read -rp "$(echo -e "${BOLD}Type 'yes' to proceed: ${RESET}")" final_confirm
[[ "$final_confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# =============================================================================
# Helpers: bridge, image, cloud-init
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

build_cloud_init_userdata() {
  local outfile=$1 hostname=$2
  cat > "$outfile" <<EOF
#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
users:
  - name: ridestatus
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${DEPLOY_PUBKEY_CONTENT}
      - ${ADMIN_SSH_PUBKEY}
package_update: true
packages:
  - curl
  - git
  - ca-certificates
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
  - mkdir -p /home/ridestatus/.ssh
  - chown -R ridestatus:ridestatus /home/ridestatus
EOF
}

build_cloud_init_network() {
  local outfile=$1
  local -n _cn_type=$2 _cn_ip=$3 _cn_gw=$4 _cn_dns=$5
  {
    echo "version: 2"
    echo "ethernets:"
    local usb_idx=0
    for i in "${!_cn_type[@]}"; do
      local iface_name
      if [[ "${_cn_type[$i]}" == "bridge" ]]; then
        iface_name="ens$((18 + i))"
      else
        iface_name="usb-placeholder-${usb_idx}"
        (( usb_idx++ ))
      fi
      echo "  ${iface_name}:"
      echo "    addresses: [${_cn_ip[$i]}]"
      [[ -n "${_cn_gw[$i]:-}" ]] && echo "    gateway4: ${_cn_gw[$i]}"
      echo "    nameservers:"
      echo "      addresses: [${_cn_dns[$i]:-8.8.8.8}]"
    done
  } > "$outfile"
}

# =============================================================================
# Helper: create and configure a VM
#
# USB passthrough uses host=<bus>-<port> (e.g. host=1-1.2) rather than
# host=<vendor>:<product>. This is unambiguous when multiple NICs of the
# same make/model are present on the host.
# =============================================================================
create_vm() {
  local vmid=$1 hostname=$2 ram_gb=$3 cores=$4 disk_gb=$5
  local -n cv_type=$6 cv_bridge=$7 cv_usb=$8 cv_ip=$9 cv_gw=${10} cv_dns=${11}

  info "Creating VM ${vmid} (${hostname})..."
  local ram_mb=$(( ram_gb * 1024 )) storage="local-lvm"

  qm create "$vmid" --name "$hostname" --memory "$ram_mb" --cores "$cores" \
    --cpu cputype=host --ostype l26 --agent enabled=1 --serial0 socket --vga serial0

  local img_copy="/tmp/ridestatus-vm${vmid}.img"
  cp "$UBUNTU_IMG_PATH" "$img_copy"
  qm importdisk "$vmid" "$img_copy" "$storage" --format qcow2
  rm -f "$img_copy"

  qm set "$vmid" --scsihw virtio-scsi-pci \
    --scsi0 "${storage}:vm-${vmid}-disk-0,discard=on" --boot order=scsi0
  qm resize "$vmid" scsi0 "${disk_gb}G"

  local bridge_nic_idx=0
  local usb_slot=0
  for i in "${!cv_type[@]}"; do
    if [[ "${cv_type[$i]}" == "bridge" ]]; then
      qm set "$vmid" --net${bridge_nic_idx} "virtio,bridge=${cv_bridge[$i]}"
      (( bridge_nic_idx++ ))
    else
      local host_iface=${cv_usb[$i]}
      local bp=${USB_NIC_BUS_PATH[$host_iface]:-}
      if [[ -z "$bp" ]]; then
        # Bus path unavailable — fall back to vendor:product with a warning
        local vp=${USB_NIC_VENDOR_PRODUCT[$host_iface]:-}
        [[ -z "$vp" ]] && die "Cannot find bus path or vendor:product for ${host_iface}"
        warn "Bus path unavailable for ${host_iface} — falling back to host=${vp} (may be ambiguous)"
        qm set "$vmid" --usb${usb_slot} "host=${vp}"
      else
        info "Assigning USB NIC ${host_iface} (MAC ${USB_NIC_MAC[$host_iface]:-unknown}) to VM ${vmid} via bus path host=${bp}"
        qm set "$vmid" --usb${usb_slot} "host=${bp}"
      fi
      (( usb_slot++ ))
    fi
  done

  local snippets="/var/lib/vz/snippets"
  mkdir -p "$snippets"
  build_cloud_init_userdata "${snippets}/vm-${vmid}-user.yaml" "$hostname"
  build_cloud_init_network  "${snippets}/vm-${vmid}-net.yaml" cv_type cv_ip cv_gw cv_dns

  qm set "$vmid" --ide2 local:cloudinit \
    --cicustom "user=local:snippets/vm-${vmid}-user.yaml,network=local:snippets/vm-${vmid}-net.yaml"

  ok "VM ${vmid} configured"
}

# =============================================================================
# Helper: wait for guest agent (reliable cloud-init-complete signal)
# =============================================================================
wait_for_guest_agent() {
  local vmid=$1 max_wait=${2:-300} elapsed=0
  info "Waiting for guest agent on VM ${vmid} (up to ${max_wait}s)..."
  while (( elapsed < max_wait )); do
    qm guest cmd "$vmid" ping &>/dev/null 2>&1 && { ok "Guest agent ready on VM ${vmid}"; return 0; }
    sleep 5; (( elapsed += 5 )); echo -n "."
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

  declare -A GA_MAC_TO_NAME
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
  declare -A USB_REAL_NAME

  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" != "usb" ]] && continue
    local host_iface=${fnn_usb[$i]}
    local host_mac; host_mac=$(iface_mac "$host_iface" | tr '[:upper:]' '[:lower:]')
    local real_name=${GA_MAC_TO_NAME[$host_mac]:-}
    local placeholder="usb-placeholder-${usb_slot}"

    if [[ -z "$real_name" ]]; then
      warn "No guest NIC matched MAC ${host_mac} — ${placeholder} may need manual fix"
    elif [[ "$real_name" != "$placeholder" ]]; then
      info "USB NIC ${host_iface} (MAC ${host_mac}) is '${real_name}' inside VM (was placeholder '${placeholder}')"
      USB_REAL_NAME["$placeholder"]="$real_name"
      needs_fix=true
    fi
    (( usb_slot++ ))
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
  local ip=$1 max_wait=60 elapsed=0
  info "Waiting for SSH on ${ip}..."
  while (( elapsed < max_wait )); do
    deploy_ssh "$ip" 'exit 0' &>/dev/null && { ok "SSH ready on ${ip}"; return 0; }
    sleep 3; (( elapsed += 3 )); echo -n "."
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
  deploy_ssh "$ip" \
    "${env_prefix}curl -fsSL '${BOOTSTRAP_BASE_URL}/${script}' | sudo -E bash" || {
    echo ""
    err "Bootstrap failed for ${script} on ${ip}."
    err "To retry: ssh ridestatus@${ip}"
    err "  curl -fsSL '${BOOTSTRAP_BASE_URL}/${script}' | sudo bash"
    return 1
  }
  ok "${script} completed on ${ip}"
}

# =============================================================================
# Helper: fetch Ansible public key from ansible.sh key server
# Used when Server VM is on this same host (Ansible VM already bootstrapped).
# =============================================================================
fetch_ansible_pubkey_from_server() {
  local ansible_ip=$1
  local url="http://${ansible_ip}:${ANSIBLE_KEY_SERVER_PORT}/ansible_ridestatus.pub"
  info "Fetching Ansible public key from ${url}..."
  local key
  key=$(curl -fsSL --max-time 10 "$url" 2>/dev/null || true)
  if [[ -z "$key" ]]; then
    warn "Could not fetch Ansible public key automatically from ${url}"
    warn "The key server may have timed out or not yet started."
    return 1
  fi
  echo "$key"
}

# =============================================================================
# EXECUTE
# =============================================================================

header "Creating Bridges"
for bridge in "${!BRIDGE_IFACE_MAP[@]}"; do ensure_bridge "$bridge"; done

ensure_ubuntu_image

# Create VMs
if $CREATE_SERVER; then
  header "Creating RideStatus Server VM (${SERVER_VMID})"
  create_vm "$SERVER_VMID" "$SERVER_HOST" "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
    SERVER_NICS_TYPE SERVER_NICS_BRIDGE SERVER_NICS_USB \
    SERVER_NICS_IP   SERVER_NICS_GW     SERVER_NICS_DNS
  qm start "$SERVER_VMID"
  ok "VM ${SERVER_VMID} started"
fi

if $CREATE_ANSIBLE; then
  header "Creating Ansible Controller VM (${ANSIBLE_VMID})"
  create_vm "$ANSIBLE_VMID" "$ANSIBLE_HOST" "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
    ANSIBLE_NICS_TYPE ANSIBLE_NICS_BRIDGE ANSIBLE_NICS_USB \
    ANSIBLE_NICS_IP   ANSIBLE_NICS_GW     ANSIBLE_NICS_DNS
  qm start "$ANSIBLE_VMID"
  ok "VM ${ANSIBLE_VMID} started"
fi

# ---- Bootstrap Ansible VM first (generates key + starts key server) --------
if $CREATE_ANSIBLE; then
  wait_for_guest_agent "$ANSIBLE_VMID"
  fix_usb_nic_names "$ANSIBLE_VMID" ANSIBLE_NICS_TYPE ANSIBLE_NICS_USB ANSIBLE_NICS_IP
  ANSIBLE_IP=$(first_ip ANSIBLE_NICS_IP)
  wait_for_ssh "$ANSIBLE_IP"
  # Run ansible.sh in background so the key server stays up while we bootstrap server
  info "Running ansible.sh on ${ANSIBLE_IP} (key server will stay up for server.sh)..."
  deploy_ssh "$ANSIBLE_IP" \
    "curl -fsSL '${BOOTSTRAP_BASE_URL}/ansible.sh' | sudo bash" &
  ANSIBLE_BOOTSTRAP_PID=$!
  # Give ansible.sh time to generate the key and start the key server
  info "Waiting for Ansible key server to start (30s)..."
  sleep 30
fi

# ---- Bootstrap Server VM ---------------------------------------------------
if $CREATE_SERVER; then
  wait_for_guest_agent "$SERVER_VMID"
  fix_usb_nic_names "$SERVER_VMID" SERVER_NICS_TYPE SERVER_NICS_USB SERVER_NICS_IP
  SERVER_IP=$(first_ip SERVER_NICS_IP)
  wait_for_ssh "$SERVER_IP"

  ANSIBLE_PUBKEY_ENV=""

  if $CREATE_ANSIBLE; then
    # Both VMs on this host — fetch key automatically
    header "Fetching Ansible Public Key Automatically"
    ANSIBLE_IP=$(first_ip ANSIBLE_NICS_IP)
    fetched_key=$(fetch_ansible_pubkey_from_server "$ANSIBLE_IP" || true)
    if [[ -n "$fetched_key" ]]; then
      ok "Ansible public key fetched automatically"
      # Pass key to server.sh via env var so it doesn't need to prompt
      ANSIBLE_PUBKEY_ENV="ANSIBLE_PUBKEY=$(printf '%q' "$fetched_key")"
    else
      warn "Auto-fetch failed. server.sh will prompt for the key URL instead."
    fi
  else
    # Ansible VM is on a different host — server.sh will prompt for the URL
    info "Ansible VM is on a separate host."
    info "server.sh will ask for the Ansible key server URL when it runs."
  fi

  run_bootstrap "$SERVER_IP" "server.sh" "$ANSIBLE_PUBKEY_ENV" || true
fi

# ---- Wait for Ansible bootstrap to finish if it's still running ------------
if $CREATE_ANSIBLE && [[ -n "${ANSIBLE_BOOTSTRAP_PID:-}" ]]; then
  info "Waiting for ansible.sh to complete..."
  wait "$ANSIBLE_BOOTSTRAP_PID" 2>/dev/null && ok "ansible.sh complete" \
    || warn "ansible.sh may have encountered errors — check logs on ${ANSIBLE_IP}"
fi

# =============================================================================
# Done
# =============================================================================
header "Deployment Complete"

$CREATE_SERVER  && ok "RideStatus Server VM ${SERVER_VMID}  (${SERVER_HOST})  — $(first_ip SERVER_NICS_IP)"
$CREATE_ANSIBLE && ok "Ansible Controller VM ${ANSIBLE_VMID} (${ANSIBLE_HOST}) — $(first_ip ANSIBLE_NICS_IP)"

echo ""
info "Next steps:"
info "  1. Verify VMs are accessible in the Proxmox web UI"
info "  2. SSH to each VM as ridestatus@<ip> using your admin key"
info "  3. Run bootstrap/edge-init.sh on each ride edge node"
echo ""
