#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="advized"
REPO_SSH="git@github.com:AlexanderJBlanchard/advized.git"
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

VMID_DEFAULT="200"
VM_NAME_DEFAULT="advized"
CORES_DEFAULT="4"
MEMORY_DEFAULT="8192"
DISK_GB_DEFAULT="64"
BRIDGE_DEFAULT="vmbr0"
STORAGE_DEFAULT="local-lvm"
CLOUD_IMAGE_STORAGE_DEFAULT="local-lvm"

say() { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33mWARNING:\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

[[ $EUID -eq 0 ]] || die "Run this installer as root from the Proxmox VE shell."
[[ -r /etc/pve/.version ]] || die "This does not appear to be a Proxmox VE host."

need qm
need pvesm
need curl
need awk
need grep
need ssh-keygen

say "Advized Proxmox Installer"
echo "This creates an Ubuntu 24.04 VM and prepares it for Advized."

read -rp "VM ID [$VMID_DEFAULT]: " VMID; VMID="${VMID:-$VMID_DEFAULT}"
read -rp "VM name [$VM_NAME_DEFAULT]: " VM_NAME; VM_NAME="${VM_NAME:-$VM_NAME_DEFAULT}"
read -rp "CPU cores [$CORES_DEFAULT]: " CORES; CORES="${CORES:-$CORES_DEFAULT}"
read -rp "RAM MB [$MEMORY_DEFAULT]: " MEMORY; MEMORY="${MEMORY:-$MEMORY_DEFAULT}"
read -rp "Disk size GB [$DISK_GB_DEFAULT]: " DISK_GB; DISK_GB="${DISK_GB:-$DISK_GB_DEFAULT}"
read -rp "Network bridge [$BRIDGE_DEFAULT]: " BRIDGE; BRIDGE="${BRIDGE:-$BRIDGE_DEFAULT}"
read -rp "VM disk storage [$STORAGE_DEFAULT]: " STORAGE; STORAGE="${STORAGE:-$STORAGE_DEFAULT}"
read -rp "Cloud image storage [$CLOUD_IMAGE_STORAGE_DEFAULT]: " CLOUD_IMAGE_STORAGE; CLOUD_IMAGE_STORAGE="${CLOUD_IMAGE_STORAGE:-$CLOUD_IMAGE_STORAGE_DEFAULT}"

qm status "$VMID" >/dev/null 2>&1 && die "VM ID $VMID already exists."
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge $BRIDGE does not exist."
pvesm status | awk 'NR>1 {print $1}' | grep -Fxq "$STORAGE" || die "Storage $STORAGE not found."
pvesm status | awk 'NR>1 {print $1}' | grep -Fxq "$CLOUD_IMAGE_STORAGE" || die "Storage $CLOUD_IMAGE_STORAGE not found."

say "Generating a read-only GitHub deploy key"
KEY_DIR="/root/.config/advized-installer"
KEY_PATH="$KEY_DIR/deploy_key"
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
if [[ ! -f "$KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -N "" -C "advized-proxmox-vm-${VMID}" -f "$KEY_PATH" >/dev/null
fi
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

echo
echo "Add this PUBLIC key to GitHub as a READ-ONLY deploy key:"
echo
cat "$KEY_PATH.pub"
echo
echo "GitHub path: Repository -> Settings -> Deploy keys -> Add deploy key"
echo "Title suggestion: Advized Proxmox VM $VMID"
echo "Leave Allow write access UNCHECKED."
echo
read -rp "Press Enter after the deploy key has been added to GitHub..."

KNOWN_HOSTS="$KEY_DIR/known_hosts"
ssh-keyscan -t ed25519 github.com > "$KNOWN_HOSTS" 2>/dev/null
chmod 600 "$KNOWN_HOSTS"

say "Deploy key prepared. The VM will validate private-repository access during first boot."

say "Downloading Ubuntu 24.04 cloud image"
IMAGE_DIR="/var/lib/vz/template/iso"
mkdir -p "$IMAGE_DIR"
IMAGE_PATH="$IMAGE_DIR/noble-server-cloudimg-amd64.img"
curl -fL "$UBUNTU_IMAGE_URL" -o "$IMAGE_PATH"

say "Creating VM $VMID ($VM_NAME)"
qm create "$VMID" --name "$VM_NAME" --ostype l26 --machine q35 --bios ovmf --cpu host --cores "$CORES" --memory "$MEMORY" --agent enabled=1 --scsihw virtio-scsi-single --net0 "virtio,bridge=$BRIDGE"
qm set "$VMID" --efidisk0 "$STORAGE:0,efitype=4m,pre-enrolled-keys=1"
qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE"
IMPORTED_VOL="$(pvesm list "$STORAGE" | awk -v id="vm-$VMID-disk-" '$1 ~ id {print $1}' | tail -n1)"
[[ -n "$IMPORTED_VOL" ]] || die "Could not determine imported disk volume."
qm set "$VMID" --scsi0 "$IMPORTED_VOL",discard=on,ssd=1
qm resize "$VMID" scsi0 "${DISK_GB}G"
qm set "$VMID" --ide2 "$CLOUD_IMAGE_STORAGE:cloudinit"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0
qm set "$VMID" --ipconfig0 ip=dhcp

read -rp "Ubuntu username [advized]: " VM_USER
VM_USER="${VM_USER:-advized}"
read -rsp "Set a temporary password for $VM_USER: " VM_PASSWORD
echo
[[ -n "$VM_PASSWORD" ]] || die "Password cannot be empty."
qm set "$VMID" --ciuser "$VM_USER" --cipassword "$VM_PASSWORD"

PUBKEY_PATH="$KEY_DIR/vm_admin.pub"
PRIVKEY_PATH="$KEY_DIR/vm_admin"
if [[ ! -f "$PRIVKEY_PATH" ]]; then
  ssh-keygen -t ed25519 -N "" -C "advized-admin-vm-${VMID}" -f "$PRIVKEY_PATH" >/dev/null
fi
qm set "$VMID" --sshkeys "$PUBKEY_PATH"

say "Creating cloud-init first-boot configuration"
if ! pvesm status | awk 'NR>1 {print $1}' | grep -Fxq "local"; then
  die "Proxmox directory storage named local is required for the Cloud-Init snippet."
fi
LOCAL_CONTENT="$(pvesm config local | awk '/^content/ {print $2}')"
if [[ ",$LOCAL_CONTENT," != *",snippets,"* ]]; then
  warn "Enabling snippets content on Proxmox storage local."
  if [[ -n "$LOCAL_CONTENT" ]]; then
    pvesm set local --content "$LOCAL_CONTENT,snippets"
  else
    pvesm set local --content snippets
  fi
fi
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"
USERDATA="$SNIPPET_DIR/advized-${VMID}-user.yaml"
DEPLOY_KEY_B64="$(base64 -w0 < "$KEY_PATH")"
KNOWN_HOSTS_B64="$(base64 -w0 < "$KNOWN_HOSTS")"

cat > "$USERDATA" <<EOF
#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl
  - git
  - gnupg
  - openssl
  - python3
  - qemu-guest-agent
write_files:
  - path: /root/.ssh/advized_deploy_key
    permissions: '0600'
    encoding: b64
    content: $DEPLOY_KEY_B64
  - path: /root/.ssh/known_hosts
    permissions: '0600'
    encoding: b64
    content: $KNOWN_HOSTS_B64
  - path: /usr/local/sbin/advized-bootstrap.sh
    permissions: '0700'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      . /etc/os-release
      echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker qemu-guest-agent
      id -u $VM_USER >/dev/null 2>&1 && usermod -aG docker $VM_USER || true
      mkdir -p /opt
      GIT_SSH_COMMAND='ssh -i /root/.ssh/advized_deploy_key -o IdentitiesOnly=yes -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=yes' git clone --branch main --depth 1 $REPO_SSH /opt/advized
      cd /opt/advized
      cp .env.example .env
      python3 - <<'PY'
      from pathlib import Path
      import secrets
      p = Path('/opt/advized/.env')
      s = p.read_text()
      s = s.replace('POSTGRES_PASSWORD=REPLACE_WITH_LONG_RANDOM_HEX_VALUE', 'POSTGRES_PASSWORD=' + secrets.token_hex(32))
      s = s.replace('SESSION_SECRET=REPLACE_WITH_AT_LEAST_32_RANDOM_CHARACTERS', 'SESSION_SECRET=' + secrets.token_hex(32))
      s = s.replace('METRICS_TOKEN=REPLACE_WITH_LONG_RANDOM_VALUE', 'METRICS_TOKEN=' + secrets.token_hex(32))
      p.write_text(s)
      PY
      chmod 600 .env
      docker compose -f compose.yaml config
      docker compose -f compose.yaml build
      docker compose -f compose.yaml up -d postgres
      touch /var/lib/advized-bootstrap-complete
runcmd:
  - [ bash, -lc, "/usr/local/sbin/advized-bootstrap.sh > /var/log/advized-bootstrap.log 2>&1" ]
final_message: "Advized bootstrap finished. Review /var/log/advized-bootstrap.log and configure /opt/advized/.env with Discord credentials."
EOF

qm set "$VMID" --cicustom "user=local:snippets/$(basename "$USERDATA")"

say "Starting VM"
qm start "$VMID"

echo
echo "Advized VM creation started."
echo "VM ID:       $VMID"
echo "VM Name:     $VM_NAME"
echo "SSH user:    $VM_USER"
echo "Admin key:   $PRIVKEY_PATH"
echo
echo "The VM will install Docker, clone the private repository, generate local secrets, build Advized, and start PostgreSQL."
echo "You still need to set DISCORD_TOKEN, CLIENT_ID, CLIENT_SECRET, and GUILD_ID in /opt/advized/.env, then start Advized with: docker compose -f /opt/advized/compose.yaml up -d"
echo
echo "To watch first boot from Proxmox:"
echo "  qm terminal $VMID"
echo
echo "After the VM gets an IP, SSH with:"
echo "  ssh -i $PRIVKEY_PATH $VM_USER@VM_IP"
echo
echo "Then check:"
echo "  sudo tail -f /var/log/advized-bootstrap.log"
