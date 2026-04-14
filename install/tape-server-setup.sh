#!/usr/bin/env bash
set -euo pipefail

# Bareos Storage Daemon — Linux Tape Server Setup
#
# Run this on the Linux VM (Ubuntu/Debian) that has the FC/SAS tape drive.
# Installs Bareos Storage Daemon natively via apt — no Docker needed.
# The Bareos Director runs on TrueNAS and connects here remotely.
#
# Usage:
#   sudo bash tape-server-setup.sh \
#     --dir-address  192.168.1.100 \
#     --sd-password  "your-sd-password" \
#     --tape-device  /dev/nst0 \
#     --media-type   LTO-8
#
# With autochanger:
#   sudo bash tape-server-setup.sh \
#     --dir-address    192.168.1.100 \
#     --sd-password    "your-sd-password" \
#     --tape-device    /dev/nst0 \
#     --changer-device /dev/sg1 \
#     --changer-slots  24 \
#     --media-type     LTO-8

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────────────
DIR_ADDRESS=""
SD_PASSWORD=""
TAPE_DEVICE="/dev/nst0"
MEDIA_TYPE="LTO-8"
DIR_NAME="bareos-dir"
SD_PORT="9103"
CHANGER_DEVICE=""
CHANGER_SLOTS="24"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir-address)    DIR_ADDRESS="$2";    shift 2 ;;
        --sd-password)    SD_PASSWORD="$2";    shift 2 ;;
        --tape-device)    TAPE_DEVICE="$2";    shift 2 ;;
        --media-type)     MEDIA_TYPE="$2";     shift 2 ;;
        --dir-name)       DIR_NAME="$2";       shift 2 ;;
        --sd-port)        SD_PORT="$2";        shift 2 ;;
        --changer-device) CHANGER_DEVICE="$2"; shift 2 ;;
        --changer-slots)  CHANGER_SLOTS="$2";  shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

[[ -z "$DIR_ADDRESS" ]] && error "--dir-address is required (TrueNAS IP)"
[[ -z "$SD_PASSWORD" ]] && error "--sd-password is required (must match TrueNAS app setting)"
[[ $EUID -ne 0 ]]       && error "Run as root: sudo bash $0 ..."

log "Bareos Storage Daemon — Tape Server Setup"
log "=========================================="
log "Director (TrueNAS): $DIR_ADDRESS"
log "Tape device:        $TAPE_DEVICE"
log "Media type:         $MEDIA_TYPE"
[[ -n "$CHANGER_DEVICE" ]] && log "Changer device:     $CHANGER_DEVICE ($CHANGER_SLOTS slots)"

# ── Check OS ─────────────────────────────────────────────────────────────────
if ! command -v apt-get &>/dev/null; then
    error "This script requires a Debian/Ubuntu system with apt."
fi

# ── Load tape kernel modules ──────────────────────────────────────────────────
log "Loading tape kernel modules..."
modprobe st       && log "  st loaded"       || warn "  st failed — tape device may not appear"
modprobe sg       && log "  sg loaded"       || warn "  sg failed"
modprobe qla2xxx  && log "  qla2xxx loaded"  || warn "  qla2xxx failed — if using FC, check your HBA driver"

# Configure st to load at boot
echo -e "st\nsg" > /etc/modules-load.d/bareos-tape.conf
log "st/sg configured to load at boot"

# ── Check tape device ─────────────────────────────────────────────────────────
if [[ -e "$TAPE_DEVICE" ]]; then
    log "Tape device found: $TAPE_DEVICE"
else
    warn "Tape device $TAPE_DEVICE not found yet."
    warn "Make sure the HBA driver is loaded and the drive is connected."
    warn "The service will start anyway — fix the device before first backup."
fi

# ── Install Bareos repository ─────────────────────────────────────────────────
log "Adding Bareos repository..."
BAREOS_VERSION="23"
. /etc/os-release

apt-get install -y curl gnupg2 lsb-release apt-transport-https ca-certificates

# Add Bareos repo key
curl -fsSL "https://download.bareos.org/bareos/release/${BAREOS_VERSION}/Debian_${VERSION_ID}/Release.key" \
    | gpg --dearmor -o /usr/share/keyrings/bareos-keyring.gpg

# Add Bareos repo
echo "deb [signed-by=/usr/share/keyrings/bareos-keyring.gpg] \
https://download.bareos.org/bareos/release/${BAREOS_VERSION}/Debian_${VERSION_ID}/ /" \
    > /etc/apt/sources.list.d/bareos.list

apt-get update -q

# ── Install Bareos Storage Daemon + tape tools ────────────────────────────────
log "Installing Bareos Storage Daemon and tape utilities..."
apt-get install -y \
    bareos-storage \
    bareos-tools \
    mt-st \
    mtx \
    lsscsi \
    sg3-utils

# ── Generate Storage Daemon config ────────────────────────────────────────────
log "Writing Bareos SD configuration..."

# bareos-sd.conf
cat > /etc/bareos/bareos-sd.d/storage/bareos-sd.conf <<EOF
Storage {
  Name = bareos-sd
  SDPort = ${SD_PORT}
  WorkingDirectory = /var/lib/bareos
  Pid Directory = /run/bareos
  Plugin Directory = /usr/lib/bareos/plugins
  Maximum Concurrent Jobs = 20
}
EOF

# Director resource (authenticates TrueNAS Director)
cat > /etc/bareos/bareos-sd.d/director/bareos-dir.conf <<EOF
Director {
  Name = ${DIR_NAME}
  Password = "${SD_PASSWORD}"
}
EOF

# Messages
cat > /etc/bareos/bareos-sd.d/messages/Standard.conf <<EOF
Messages {
  Name = Standard
  Director = ${DIR_NAME} = all
}
EOF

# ── Generate Device config ────────────────────────────────────────────────────
if [[ -n "$CHANGER_DEVICE" ]]; then
    log "Writing autochanger device config..."
    cat > /etc/bareos/bareos-sd.d/autochanger/TapeChanger.conf <<EOF
Autochanger {
  Name = TapeChanger
  Device = TapeDevice
  Changer Command = "/usr/lib/bareos/scripts/mtx-changer %c %o %S %a %d"
  Changer Device = ${CHANGER_DEVICE}
}
EOF
    cat > /etc/bareos/bareos-sd.d/device/TapeDevice.conf <<EOF
Device {
  Name = TapeDevice
  Media Type = ${MEDIA_TYPE}
  Archive Device = ${TAPE_DEVICE}
  AutoChanger = yes
  AutomaticMount = yes
  AlwaysOpen = yes
  RemovableMedia = yes
  RandomAccess = no
  Hardware End of Medium = yes
  Fast Forward Space File = no
  BSF at EOM = yes
  Maximum Block Size = 1048576
  Label Media = yes
}
EOF
else
    log "Writing single-drive device config..."
    cat > /etc/bareos/bareos-sd.d/device/TapeDevice.conf <<EOF
Device {
  Name = TapeDevice
  Media Type = ${MEDIA_TYPE}
  Archive Device = ${TAPE_DEVICE}
  AutomaticMount = yes
  AlwaysOpen = yes
  RemovableMedia = yes
  RandomAccess = no
  Hardware End of Medium = yes
  Fast Forward Space File = no
  BSF at EOM = yes
  Maximum Block Size = 1048576
  Label Media = yes
}
EOF
fi

# Fix permissions
chown -R bareos:bareos /etc/bareos/bareos-sd.d/
chmod 640 /etc/bareos/bareos-sd.d/director/bareos-dir.conf  # contains password

# ── Enable and start service ──────────────────────────────────────────────────
log "Enabling and starting bareos-sd..."
systemctl enable bareos-sd
systemctl restart bareos-sd
sleep 2

if systemctl is-active --quiet bareos-sd; then
    log "bareos-sd is running"
else
    warn "bareos-sd failed to start — check logs: journalctl -u bareos-sd -n 30"
fi

# ── Open firewall port ────────────────────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "Opening port ${SD_PORT} in ufw..."
    ufw allow "${SD_PORT}/tcp" comment "Bareos Storage Daemon"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
log "============================================"
log "  Tape Server Setup Complete"
log "============================================"
echo ""
echo "  Service status:    systemctl status bareos-sd"
echo "  Logs:              journalctl -u bareos-sd -f"
echo "  Tape device:       ls -la $TAPE_DEVICE"
echo "  Test tape:         mt -f $TAPE_DEVICE status"
echo ""
echo "  Now on TrueNAS, run:"
echo "    midclt call tape_backup.bareos.setup"
echo ""
echo "  Make sure port ${SD_PORT} is reachable from TrueNAS:"
echo "    nc -zv $DIR_ADDRESS ${SD_PORT}"
echo ""
