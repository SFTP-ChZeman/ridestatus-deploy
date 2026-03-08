#!/usr/bin/env bash
# =============================================================================
# RideStatus — Proxmox Deploy Script
# https://github.com/RideStatus/ridestatus-deploy
#
# Run once per Proxmox host as root.
# Creates RideStatus Server VM and/or Ansible Controller VM.
# Walks the tech through NIC topology, VM IDs, and resource sizing.
# After VM creation, SSHs in and runs the appropriate bootstrap script.
#
# SSH approach:
#   A temporary ed25519 keypair is generated at startup and injected into
#   cloud-init alongside the tech's admin key. The script uses the temp key
#   exclusively for bootstrap SSH connections, then deletes it. This avoids
#   any dependency on what's in the tech's SSH agent.
#
# USB NIC naming:
#   After each VM boots, we wait for the QEMU guest agent, then query
#   qm guest cmd <vmid> network-get-interfaces to get the real interface
#   names from inside the VM. If any USB passthrough NIC names differ from
#   what cloud-init configured, we patch the netplan config in-place and
#   apply it before running bootstrap.
#
# Usage: bash proxmox/deploy.sh
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------------
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

# Numbered menu — sets _pick to 0-based index of chosen option
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

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
header "RideStatus Proxmox Deploy"

[[ $EUID -eq 0 ]] || die "This script must be run as root."
command -v pvesh   >/dev/null 2>&1 || die "pvesh not found — is this a Proxmox host?"
command -v qm      >/dev/null 2>&1 || die "qm not found — is this a Proxmox host?"
command -v lsusb   >/dev/null 2>&1 || die "lsusb not found (apt install usbutils)"
command -v ssh     >/dev/null 2>&1 || die "ssh not found"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found (needed for JSON parsing)"

PROXMOX_NODE=$(hostname)
info "Proxmox node: ${PROXMOX_NODE}"

# -----------------------------------------------------------------------------
# Generate temporary deploy keypair
# Used exclusively for bootstrap SSH — deleted at script exit.
# The tech's admin key is also injected so they can SSH in afterwards.
# -----------------------------------------------------------------------------
DEPLOY_KEY_DIR=$(mktemp -d /tmp/ridestatus-deploy-XXXXXX)
DEPLOY_KEY="${DEPLOY_KEY_DIR}/id_ed25519"
DEPLOY_PUBKEY="${DEPLOY_KEY}.pub"

ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "ridestatus-deploy-temp" -q
DEPLOY_PUBKEY_CONTENT=$(cat "$DEPLOY_PUBKEY")
ok "Temporary deploy keypair generated (will be deleted on exit)"

cleanup() {
  rm -rf "$DEPLOY_KEY_DIR"
  # Remove temp cloud-init snippets
  rm -f /var/lib/vz/snippets/vm-*-user.yaml \
        /var/lib/vz/snippets/vm-*-net.yaml 2>/dev/null || true
}
trap cleanup EXIT

# SSH helper that always uses the temp deploy key and skips host key checking.
# Usage: deploy_ssh <ip> <command>
deploy_ssh() {
  local ip=$1; shift
  ssh -i "$DEPLOY_KEY" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "ridestatus@${ip}" "$@"
}

# -----------------------------------------------------------------------------
# Detect physical interfaces and existing bridges
# -----------------------------------------------------------------------------
header "Detecting Network Interfaces"

mapfile -t ALL_IFACES < <(
  ip -o link show \
  | awk -F': ' '{print $2}' \
  | grep -v '^lo$' \
  | grep -Ev '^(vmbr|tap|veth|fwbr|fwpr)'
)

mapfile -t EXISTING_BRIDGES < <(
  brctl show 2>/dev/null | awk 'NR>1 && $1!="" {print $1}' || true
)

echo ""
info "Physical interfaces found:"
for iface in "${ALL_IFACES[@]}"; do
  mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "unknown")
  state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "unknown")
  is_usb=""
  readlink -f "/sys/class/net/${iface}/device" 2>/dev/null | grep -q '/usb' && is_usb=" [USB]"
  echo "  ${iface}  MAC=${mac}  state=${state}${is_usb}"
done

# -----------------------------------------------------------------------------
# Enumerate USB NICs — build free list (exclude already passed-through)
# -----------------------------------------------------------------------------
header "USB NIC Detection"

declare -A USB_NIC_VENDOR_PRODUCT  # iface -> vendor:product
declare -A USB_NIC_CLAIMED_BY      # vendor:product -> vmid
declare -a FREE_USB_NICS

for iface in "${ALL_IFACES[@]}"; do
  syspath=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)
  if echo "$syspath" | grep -q '/usb'; then
    usb_dir=$(echo "$syspath" | sed 's|/[^/]*$||')
    vp=$(cat "${usb_dir}/idVendor"  2>/dev/null || true)
    pp=$(cat "${usb_dir}/idProduct" 2>/dev/null || true)
    [[ -n "$vp" && -n "$pp" ]] && USB_NIC_VENDOR_PRODUCT["$iface"]="${vp}:${pp}"
  fi
done

if [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -gt 0 ]]; then
  mapfile -t ALL_VMIDS < <(
    pvesh get "/nodes/${PROXMOX_NODE}/qemu" --output-format json 2>/dev/null \
    | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*' || true
  )
  for vmid in "${ALL_VMIDS[@]}"; do
    vm_config=$(pvesh get "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
                --output-format json 2>/dev/null || true)
    while IFS= read -r usb_entry; do
      vp=$(echo "$usb_entry" | grep -o 'host=[0-9a-f]*:[0-9a-f]*' | sed 's/host=//' || true)
      [[ -n "$vp" ]] && USB_NIC_CLAIMED_BY["$vp"]="$vmid"
    done < <(echo "$vm_config" | grep -o '"usb[0-9]*":"[^"]*"' || true)
  done
fi

for iface in "${!USB_NIC_VENDOR_PRODUCT[@]}"; do
  vp=${USB_NIC_VENDOR_PRODUCT[$iface]}
  [[ -z "${USB_NIC_CLAIMED_BY[$vp]:-}" ]] && FREE_USB_NICS+=("$iface")
done

if   [[ ${#USB_NIC_VENDOR_PRODUCT[@]} -eq 0 ]]; then
  info "No USB NICs detected on this host."
elif [[ ${#FREE_USB_NICS[@]} -eq 0 ]]; then
  warn "USB NICs found but all are already passed through to existing VMs."
  warn "USB passthrough will not be offered as an option."
else
  info "Free USB NICs available for passthrough:"
  for iface in "${FREE_USB_NICS[@]}"; do
    mac=$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "unknown")
    echo "  ${iface}  MAC=${mac}  vendor:product=${USB_NIC_VENDOR_PRODUCT[$iface]}"
  done
fi

# -----------------------------------------------------------------------------
# Which VMs to create
# -----------------------------------------------------------------------------
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
declare -A BRIDGE_IFACE_MAP  # bridge -> physical NIC (for new bridges)

# -----------------------------------------------------------------------------
# NIC configuration helper
# Populates VM_NICS_TYPE[], VM_NICS_LABEL[], VM_NICS_BRIDGE[],
# VM_NICS_USB[], VM_NICS_IP[], VM_NICS_GW[], VM_NICS_DNS[]
# -----------------------------------------------------------------------------
configure_vm_nics() {
  local vm_label=$1
  VM_NICS_TYPE=(); VM_NICS_LABEL=(); VM_NICS_BRIDGE=()
  VM_NICS_USB=();  VM_NICS_IP=();   VM_NICS_GW=(); VM_NICS_DNS=()

  local nic_num=1
  while true; do
    echo ""
    echo -e "${BOLD}--- ${vm_label}: vNIC${nic_num} ---${RESET}"

    local net_label
    prompt_required net_label \
      "What network does vNIC${nic_num} connect to? (e.g. Department, Corporate VLAN)"

    # Build available connection methods
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

    local nic_type="" bridge_name="" usb_iface="" ip_cidr="" gw="" dns=""

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
        for iface in "${ALL_IFACES[@]}"; do echo "  ${iface}"; done
        local onboard_iface
        prompt_required onboard_iface "Physical NIC to attach to ${bridge_name}"
        BRIDGE_IFACE_MAP["$bridge_name"]="$onboard_iface"
        EXISTING_BRIDGES+=("$bridge_name")
      fi

    else
      nic_type="usb"

      if [[ ${#available_usb[@]} -eq 1 ]]; then
        usb_iface=${available_usb[0]}
        info "Using only available free USB NIC: ${usb_iface}"
      else
        local usb_opts=()
        for u in "${available_usb[@]}"; do
          local mac; mac=$(cat "/sys/class/net/${u}/address" 2>/dev/null || echo "unknown")
          usb_opts+=("${u}  MAC=${mac}  (${USB_NIC_VENDOR_PRODUCT[$u]})")
        done
        local usb_idx=0
        pick_menu usb_idx "Which USB NIC?" "${usb_opts[@]}"
        usb_iface=${available_usb[$usb_idx]}
      fi

      SESSION_CLAIMED_USB+=("$usb_iface")
      ok "Reserved ${usb_iface} for ${vm_label} vNIC${nic_num}"
    fi

    prompt_required ip_cidr \
      "Static IP and prefix for ${net_label} (e.g. 10.15.140.101/25)"

    gw=""
    if confirm "Is this the default-route NIC for ${vm_label}?"; then
      prompt_required gw "Default gateway"
    fi

    prompt_default dns "DNS server" "8.8.8.8"

    VM_NICS_TYPE+=("$nic_type")
    VM_NICS_LABEL+=("$net_label")
    VM_NICS_BRIDGE+=("$bridge_name")
    VM_NICS_USB+=("$usb_iface")
    VM_NICS_IP+=("$ip_cidr")
    VM_NICS_GW+=("$gw")
    VM_NICS_DNS+=("$dns")

    (( nic_num++ ))
    confirm "Add another NIC to ${vm_label}?" || break
  done
}

# -----------------------------------------------------------------------------
# Collect NIC config for each VM being created
# -----------------------------------------------------------------------------
if $CREATE_SERVER; then
  header "RideStatus Server VM — NIC Configuration"
  configure_vm_nics "Server VM"
  SERVER_NICS_TYPE=("${VM_NICS_TYPE[@]}")
  SERVER_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  SERVER_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}")
  SERVER_NICS_USB=("${VM_NICS_USB[@]}")
  SERVER_NICS_IP=("${VM_NICS_IP[@]}")
  SERVER_NICS_GW=("${VM_NICS_GW[@]}")
  SERVER_NICS_DNS=("${VM_NICS_DNS[@]}")
fi

if $CREATE_ANSIBLE; then
  header "Ansible Controller VM — NIC Configuration"
  configure_vm_nics "Ansible VM"
  ANSIBLE_NICS_TYPE=("${VM_NICS_TYPE[@]}")
  ANSIBLE_NICS_LABEL=("${VM_NICS_LABEL[@]}")
  ANSIBLE_NICS_BRIDGE=("${VM_NICS_BRIDGE[@]}")
  ANSIBLE_NICS_USB=("${VM_NICS_USB[@]}")
  ANSIBLE_NICS_IP=("${VM_NICS_IP[@]}")
  ANSIBLE_NICS_GW=("${VM_NICS_GW[@]}")
  ANSIBLE_NICS_DNS=("${VM_NICS_DNS[@]}")
fi

# -----------------------------------------------------------------------------
# VM IDs
# -----------------------------------------------------------------------------
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
      suggested=$(next_free_vmid)
      warn "Next available ID: ${suggested}"
    else
      break
    fi
  done
}

if $CREATE_SERVER;  then pick_vmid SERVER_VMID  "RideStatus Server"; fi
if $CREATE_ANSIBLE; then pick_vmid ANSIBLE_VMID "Ansible Controller"; fi

# -----------------------------------------------------------------------------
# VM resources and hostnames
# -----------------------------------------------------------------------------
header "VM Resources"

if $CREATE_SERVER; then
  prompt_default SERVER_RAM   "Server VM RAM (GB)"   "4"
  prompt_default SERVER_CORES "Server VM CPU cores"  "2"
  prompt_default SERVER_DISK  "Server VM disk (GB)"  "32"
  prompt_default SERVER_HOST  "Server VM hostname"   "ridestatus-server"
fi

if $CREATE_ANSIBLE; then
  prompt_default ANSIBLE_RAM   "Ansible VM RAM (GB)"  "2"
  prompt_default ANSIBLE_CORES "Ansible VM CPU cores" "2"
  prompt_default ANSIBLE_DISK  "Ansible VM disk (GB)" "20"
  prompt_default ANSIBLE_HOST  "Ansible VM hostname"  "ridestatus-ansible"
fi

prompt_required ADMIN_SSH_PUBKEY \
  "Admin SSH public key (paste full public key — added alongside deploy key)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
header "Summary — Review Before Proceeding"

print_vm_summary() {
  local label=$1 vmid=$2 hostname=$3 ram=$4 cores=$5 disk=$6
  local -n _nt=$7 _nl=$8 _nb=$9 _nu=${10} _ni=${11} _ng=${12}
  echo -e "  ${BOLD}${label}${RESET}"
  echo "    VM ID:    ${vmid}"
  echo "    Hostname: ${hostname}"
  echo "    RAM:      ${ram}GB    Cores: ${cores}    Disk: ${disk}GB"
  for i in "${!_nt[@]}"; do
    local conn=""
    if [[ "${_nt[$i]}" == "bridge" ]]; then
      conn="bridge=${_nb[$i]}"
    else
      conn="USB passthrough=${_nu[$i]} (${USB_NIC_VENDOR_PRODUCT[${_nu[$i]}]:-unknown})"
    fi
    local gw_str=""; [[ -n "${_ng[$i]:-}" ]] && gw_str="  GW=${_ng[$i]}"
    echo "    vNIC$((i+1)):   ${_nl[$i]}  IP=${_ni[$i]}${gw_str}  [${conn}]"
  done
}

echo ""
if $CREATE_SERVER; then
  print_vm_summary "RideStatus Server" "$SERVER_VMID" "$SERVER_HOST" \
    "$SERVER_RAM" "$SERVER_CORES" "$SERVER_DISK" \
    SERVER_NICS_TYPE SERVER_NICS_LABEL SERVER_NICS_BRIDGE \
    SERVER_NICS_USB  SERVER_NICS_IP    SERVER_NICS_GW
fi
echo ""
if $CREATE_ANSIBLE; then
  print_vm_summary "Ansible Controller" "$ANSIBLE_VMID" "$ANSIBLE_HOST" \
    "$ANSIBLE_RAM" "$ANSIBLE_CORES" "$ANSIBLE_DISK" \
    ANSIBLE_NICS_TYPE ANSIBLE_NICS_LABEL ANSIBLE_NICS_BRIDGE \
    ANSIBLE_NICS_USB  ANSIBLE_NICS_IP    ANSIBLE_NICS_GW
fi

echo ""
warn "This will create VMs and modify network configuration on this Proxmox host."
read -rp "$(echo -e "${BOLD}Type 'yes' to proceed or anything else to abort: ${RESET}")" final_confirm
[[ "$final_confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# -----------------------------------------------------------------------------
# Helper: create Linux bridge if it doesn't exist
# -----------------------------------------------------------------------------
ensure_bridge() {
  local bridge=$1
  if ! ip link show "$bridge" &>/dev/null 2>&1; then
    local phys=${BRIDGE_IFACE_MAP[$bridge]:-none}
    info "Creating bridge ${bridge} (attached to ${phys})"
    local net_conf="/etc/network/interfaces.d/${bridge}"
    {
      echo "auto ${bridge}"
      echo "iface ${bridge} inet manual"
      echo "  bridge_ports ${phys}"
      echo "  bridge_stp off"
      echo "  bridge_fd 0"
    } > "$net_conf"
    ifup "$bridge" 2>/dev/null || true
    ok "Bridge ${bridge} created"
  else
    info "Bridge ${bridge} already exists — skipping"
  fi
}

# -----------------------------------------------------------------------------
# Helper: download Ubuntu 24.04 cloud image
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Helper: build cloud-init user-data
# Injects BOTH the temp deploy key and the tech's admin key.
# Also installs qemu-guest-agent so we can query NICs after boot.
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Helper: build cloud-init network config
# Bridged NICs use predictable ens18/ens19/... names (virtio, PCI slot order).
# USB passthrough NICs use a placeholder name that we fix up post-boot
# via the guest agent (see fix_usb_nic_names below).
# -----------------------------------------------------------------------------
build_cloud_init_network() {
  local outfile=$1
  local -n _cn_type=$2 _cn_ip=$3 _cn_gw=$4 _cn_dns=$5

  {
    echo "version: 2"
    echo "ethernets:"
    local usb_idx=0
    for i in "${!_cn_type[@]}"; do
      local ip=${_cn_ip[$i]}
      local gw=${_cn_gw[$i]:-}
      local dns=${_cn_dns[$i]:-8.8.8.8}

      local iface_name
      if [[ "${_cn_type[$i]}" == "bridge" ]]; then
        # virtio NICs appear as ens18, ens19, ... in PCI slot order
        iface_name="ens$((18 + i))"
      else
        # USB NIC placeholder — corrected post-boot via fix_usb_nic_names()
        iface_name="usb-placeholder-${usb_idx}"
        (( usb_idx++ ))
      fi

      echo "  ${iface_name}:"
      echo "    addresses: [${ip}]"
      [[ -n "$gw" ]] && echo "    gateway4: ${gw}"
      echo "    nameservers:"
      echo "      addresses: [${dns}]"
    done
  } > "$outfile"
}

# -----------------------------------------------------------------------------
# Helper: create and configure a VM (does not start it)
# -----------------------------------------------------------------------------
create_vm() {
  local vmid=$1 hostname=$2 ram_gb=$3 cores=$4 disk_gb=$5
  local -n cv_type=$6 cv_bridge=$7 cv_usb=$8 cv_ip=$9 cv_gw=${10} cv_dns=${11}

  info "Creating VM ${vmid} (${hostname})..."

  local ram_mb=$(( ram_gb * 1024 ))
  local storage="local-lvm"

  qm create "$vmid" \
    --name "$hostname" \
    --memory "$ram_mb" \
    --cores "$cores" \
    --cpu cputype=host \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket --vga serial0

  local img_copy="/tmp/ridestatus-vm${vmid}.img"
  cp "$UBUNTU_IMG_PATH" "$img_copy"
  qm importdisk "$vmid" "$img_copy" "$storage" --format qcow2
  rm -f "$img_copy"

  qm set "$vmid" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${storage}:vm-${vmid}-disk-0,discard=on" \
    --boot order=scsi0

  qm resize "$vmid" scsi0 "${disk_gb}G"

  # Attach vNICs (bridged) and USB passthrough devices
  local bridge_nic_idx=0
  for i in "${!cv_type[@]}"; do
    if [[ "${cv_type[$i]}" == "bridge" ]]; then
      qm set "$vmid" --net${bridge_nic_idx} "virtio,bridge=${cv_bridge[$i]}"
      (( bridge_nic_idx++ ))
    else
      local vp=${USB_NIC_VENDOR_PRODUCT[${cv_usb[$i]}]:-}
      [[ -z "$vp" ]] && die "Cannot find vendor:product for USB NIC ${cv_usb[$i]}"
      qm set "$vmid" --usb${i} "host=${vp}"
    fi
  done

  # cloud-init snippets
  local snippets_dir="/var/lib/vz/snippets"
  mkdir -p "$snippets_dir"

  build_cloud_init_userdata "${snippets_dir}/vm-${vmid}-user.yaml" "$hostname"
  build_cloud_init_network  "${snippets_dir}/vm-${vmid}-net.yaml" \
    cv_type cv_ip cv_gw cv_dns

  qm set "$vmid" \
    --ide2 local:cloudinit \
    --cicustom "user=local:snippets/vm-${vmid}-user.yaml,network=local:snippets/vm-${vmid}-net.yaml"

  ok "VM ${vmid} configured"
}

# -----------------------------------------------------------------------------
# Helper: wait for QEMU guest agent to become available
# The guest agent starts after cloud-init finishes, so this is a reliable
# signal that the VM is fully up and cloud-init is complete.
# -----------------------------------------------------------------------------
wait_for_guest_agent() {
  local vmid=$1 max_wait=${2:-300} elapsed=0
  info "Waiting for QEMU guest agent on VM ${vmid} (up to ${max_wait}s)..."
  while (( elapsed < max_wait )); do
    if qm guest cmd "$vmid" ping &>/dev/null 2>&1; then
      ok "Guest agent ready on VM ${vmid}"
      return 0
    fi
    sleep 5; (( elapsed += 5 )); echo -n "."
  done
  echo ""
  die "Timed out waiting for guest agent on VM ${vmid}"
}

# -----------------------------------------------------------------------------
# Helper: fix USB NIC names in netplan using guest agent data
#
# After the VM boots, qm guest cmd <vmid> network-get-interfaces returns
# the real interface names (including USB NICs). We compare against what
# cloud-init configured and patch any usb-placeholder-N entries in the
# netplan file with the real name, then run netplan apply inside the VM.
#
# USB NICs are identified by matching their MAC address against the MAC
# of the USB NIC as seen from the Proxmox host (in USB_NIC_VENDOR_PRODUCT).
# -----------------------------------------------------------------------------
fix_usb_nic_names() {
  local vmid=$1
  local -n fnn_type=$2 fnn_usb=$3 fnn_ip=$4

  # Check if any NICs are USB type
  local has_usb=false
  for t in "${fnn_type[@]}"; do [[ "$t" == "usb" ]] && has_usb=true && break; done
  $has_usb || return 0

  info "Querying guest agent for NIC names in VM ${vmid}..."

  local ga_json
  ga_json=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null || true)
  if [[ -z "$ga_json" ]]; then
    warn "Could not get NIC list from guest agent — USB NIC names may need manual correction"
    return 0
  fi

  # Parse the guest agent JSON to get name->mac mapping
  # qm guest cmd returns Proxmox-wrapped JSON: {"result": [...]}
  # Each element: {"name":"eth0","hardware-address":"aa:bb:cc:dd:ee:ff",...}
  declare -A GA_MAC_TO_NAME  # lowercase mac -> iface name inside VM
  while IFS= read -r line; do
    local name mac
    name=$(echo "$line" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || true)
    mac=$(echo "$line"  | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('hardware-address','').lower())" \
      2>/dev/null || true)
    [[ -n "$name" && -n "$mac" ]] && GA_MAC_TO_NAME["$mac"]="$name"
  done < <(echo "$ga_json" | python3 -c \
    "import sys,json; [print(json.dumps(x)) for x in json.load(sys.stdin).get('result',[])]" \
    2>/dev/null || true)

  if [[ ${#GA_MAC_TO_NAME[@]} -eq 0 ]]; then
    warn "Guest agent returned no NIC data — skipping USB NIC name correction"
    return 0
  fi

  # For each USB NIC, find its real name via MAC
  local usb_slot=0
  local needs_fix=false
  declare -A USB_REAL_NAME  # placeholder-N -> real iface name

  for i in "${!fnn_type[@]}"; do
    [[ "${fnn_type[$i]}" != "usb" ]] && continue
    local host_iface=${fnn_usb[$i]}
    local host_mac; host_mac=$(cat "/sys/class/net/${host_iface}/address" 2>/dev/null \
                               | tr '[:upper:]' '[:lower:]' || echo "")

    if [[ -z "$host_mac" ]]; then
      warn "Could not read MAC for ${host_iface} — skipping correction for USB NIC $((usb_slot))"
      (( usb_slot++ )); continue
    fi

    local real_name=${GA_MAC_TO_NAME[$host_mac]:-}
    local placeholder="usb-placeholder-${usb_slot}"

    if [[ -z "$real_name" ]]; then
      warn "No guest NIC found with MAC ${host_mac} — ${placeholder} may need manual correction"
    elif [[ "$real_name" != "$placeholder" ]]; then
      info "USB NIC ${host_iface}: inside VM name is '${real_name}' (placeholder was '${placeholder}')"
      USB_REAL_NAME["$placeholder"]="$real_name"
      needs_fix=true
    else
      ok "USB NIC name matches placeholder: ${real_name}"
    fi
    (( usb_slot++ ))
  done

  if ! $needs_fix; then
    ok "All NIC names correct — no netplan patch needed"
    return 0
  fi

  # Determine which VM IP to SSH to (first bridged NIC, or first USB if all are USB)
  local ssh_ip=""
  for i in "${!fnn_type[@]}"; do
    if [[ "${fnn_type[$i]}" == "bridge" ]]; then
      ssh_ip="${fnn_ip[$i]%%/*}"; break
    fi
  done
  if [[ -z "$ssh_ip" ]]; then
    ssh_ip="${fnn_ip[0]%%/*}"
  fi

  info "Patching netplan in VM ${vmid} via SSH (${ssh_ip})..."

  # Build sed expressions to rename placeholders in the netplan file
  local sed_args=()
  for placeholder in "${!USB_REAL_NAME[@]}"; do
    local real=${USB_REAL_NAME[$placeholder]}
    sed_args+=(-e "s/${placeholder}/${real}/g")
  done

  # Find and patch the netplan file inside the VM, then apply
  deploy_ssh "$ssh_ip" "
    set -e
    netplan_file=\$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    if [[ -z \"\$netplan_file\" ]]; then
      echo 'No netplan file found'; exit 1
    fi
    sudo sed -i ${sed_args[*]} \"\$netplan_file\"
    sudo netplan apply
  " && ok "Netplan patched and applied in VM ${vmid}" \
    || warn "Netplan patch failed — USB NIC names may need manual correction"
}

# -----------------------------------------------------------------------------
# Helper: find first IP for a VM (used for SSH)
# -----------------------------------------------------------------------------
first_ip() {
  local -n _fi=$1
  echo "${_fi[0]%%/*}"
}

# -----------------------------------------------------------------------------
# Helper: wait for SSH using the temp deploy key
# Runs after wait_for_guest_agent, so cloud-init is already complete.
# Should succeed on the first or second try.
# -----------------------------------------------------------------------------
wait_for_ssh() {
  local ip=$1 max_wait=60 elapsed=0
  info "Waiting for SSH on ${ip}..."
  while (( elapsed < max_wait )); do
    deploy_ssh "$ip" 'exit 0' &>/dev/null && { ok "SSH ready on ${ip}"; return 0; }
    sleep 3; (( elapsed += 3 )); echo -n "."
  done
  echo ""
  die "Timed out waiting for SSH on ${ip}"
}

# -----------------------------------------------------------------------------
# Helper: run bootstrap script inside a VM
# -----------------------------------------------------------------------------
BOOTSTRAP_BASE_URL="https://raw.githubusercontent.com/RideStatus/ridestatus-deploy/main/bootstrap"

run_bootstrap() {
  local ip=$1 script=$2
  info "Running ${script} on ${ip}..."
  deploy_ssh "$ip" \
    "curl -fsSL '${BOOTSTRAP_BASE_URL}/${script}' | sudo bash" || {
    echo ""
    err "Bootstrap failed for ${script} on ${ip}."
    err "To retry manually, SSH to ridestatus@${ip} and run:"
    err "  curl -fsSL '${BOOTSTRAP_BASE_URL}/${script}' | sudo bash"
    return 1
  }
  ok "${script} completed on ${ip}"
}

# =============================================================================
# EXECUTE
# =============================================================================

header "Creating Bridges"
for bridge in "${!BRIDGE_IFACE_MAP[@]}"; do
  ensure_bridge "$bridge"
done

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

# Wait for guest agent (signals cloud-init complete), fix USB NIC names, run bootstrap
if $CREATE_SERVER; then
  wait_for_guest_agent "$SERVER_VMID"
  fix_usb_nic_names "$SERVER_VMID" \
    SERVER_NICS_TYPE SERVER_NICS_USB SERVER_NICS_IP
  wait_for_ssh "$(first_ip SERVER_NICS_IP)"
  run_bootstrap "$(first_ip SERVER_NICS_IP)" "server.sh" || true
fi

if $CREATE_ANSIBLE; then
  wait_for_guest_agent "$ANSIBLE_VMID"
  fix_usb_nic_names "$ANSIBLE_VMID" \
    ANSIBLE_NICS_TYPE ANSIBLE_NICS_USB ANSIBLE_NICS_IP
  wait_for_ssh "$(first_ip ANSIBLE_NICS_IP)"
  run_bootstrap "$(first_ip ANSIBLE_NICS_IP)" "ansible.sh" || true
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
info "  2. SSH to each VM as ridestatus@<ip> using your admin key to confirm access"
info "  3. Run bootstrap/edge-init.sh on each ride edge node"
echo ""
