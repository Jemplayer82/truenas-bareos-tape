#!/usr/bin/env bash
set -euo pipefail

# Bareos Storage Daemon — Linux Tape Server Setup
#
# Run this on the Linux machine that has the FC/SAS tape drive.
# The Bareos Director runs on TrueNAS and connects here remotely.
#
# Usage:
#   sudo bash tape-server-setup.sh \
#     --dir-address  192.168.1.100 \
#     --sd-password  "your-sd-password" \
#     --tape-device  /dev/nst0 \
#     --media-type   LTO-8 \
#     --dir-name     bareos-dir
#
# Autochanger (optional):
#     --changer-device /dev/sg1 \
#     --changer-slots  24

BAREOS_CONFIG_DIR="/etc/bareos-sd"
BAREOS_DATA_DIR="/var/lib/bareos-sd"
SD_CONTAINER="bareos-sd"
SD_IMAGE="barcus/bareos-storage:23-ubuntu"

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

if [[ $EUID -ne 0 ]]; then
    error "Run as root: sudo bash $0 ..."
fi

log "Bareos Storage Daemon — Tape Server Setup"
log "=========================================="
log "Director (TrueNAS): $DIR_ADDRESS"
log "Tape device:        $TAPE_DEVICE"
log "Media type:         $MEDIA_TYPE"

# ── Check Docker ─────────────────────────────────────────────────────────────
log "Checking Docker..."
command -v docker &>/dev/null || error "Docker is not installed."
docker info &>/dev/null       || error "Docker daemon is not running."

# ── Check tape modules ───────────────────────────────────────────────────────
log "Checking tape kernel modules..."
if ! lsmod | grep -q "^st "; then
    log "Loading st (SCSI tape) module..."
    modprobe st || warn "Could not load st module — tape device may not appear."
fi

if ! lsmod | grep -q "^qla2xxx "; then
    log "Trying to load qla2xxx (FC HBA) module..."
    modprobe qla2xxx 2>/dev/null && log "qla2xxx loaded" || warn "Could not load qla2xxx — if using FC, load the HBA driver manually."
fi

# Verify tape device exists
if [[ ! -e "$TAPE_DEVICE" ]]; then
    warn "Tape device $TAPE_DEVICE not found."
    warn "Make sure the HBA driver is loaded and the drive is connected."
    warn "Continuing anyway — fix before starting the container."
fi

# ── Create directories ───────────────────────────────────────────────────────
log "Creating directories..."
mkdir -p "$BAREOS_CONFIG_DIR" "$BAREOS_DATA_DIR"

# ── Generate Storage Daemon config ───────────────────────────────────────────
log "Generating Bareos SD configuration..."

cat > "$BAREOS_CONFIG_DIR/bareos-sd.conf" <<EOF
Storage {
  Name = bareos-sd
  SDPort = ${SD_PORT}
  WorkingDirectory = /var/lib/bareos
  Pid Directory = /run/bareos
  Plugin Directory = /usr/lib/bareos/plugins
  Maximum Concurrent Jobs = 20
}

Director {
  Name = ${DIR_NAME}
  Password = "${SD_PASSWORD}"
}

Messages {
  Name = Standard
  Director = ${DIR_NAME} = all
}
EOF

# ── Generate Device config ───────────────────────────────────────────────────
if [[ -n "$CHANGER_DEVICE" ]]; then
    # Autochanger config
    cat > "$BAREOS_CONFIG_DIR/device-tape.conf" <<EOF
Autochanger {
  Name = TapeChanger
  Device = TapeDevice
  Changer Command = "/usr/lib/bareos/scripts/mtx-changer %c %o %S %a %d"
  Changer Device = ${CHANGER_DEVICE}
}

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
    log "Autochanger config written (${CHANGER_SLOTS} slots, device: $CHANGER_DEVICE)"
else
    # Single drive config
    cat > "$BAREOS_CONFIG_DIR/device-tape.conf" <<EOF
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

# ── Pull SD image ────────────────────────────────────────────────────────────
log "Pulling Bareos Storage Daemon image..."
docker pull "$SD_IMAGE"

# ── Stop existing container ──────────────────────────────────────────────────
if docker inspect "$SD_CONTAINER" &>/dev/null; then
    log "Stopping existing bareos-sd container..."
    docker stop "$SD_CONTAINER" 2>/dev/null || true
    docker rm "$SD_CONTAINER" 2>/dev/null || true
fi

# ── Build docker run command ─────────────────────────────────────────────────
SD_CMD=(
    docker run -d
    --name "$SD_CONTAINER"
    --restart unless-stopped
    -p "${SD_PORT}:${SD_PORT}"
    --cap-add SYS_RAWIO
)

# Pass through tape device
if [[ -e "$TAPE_DEVICE" ]]; then
    SD_CMD+=(--device "${TAPE_DEVICE}:${TAPE_DEVICE}")
else
    warn "Skipping --device (tape device not found yet)"
fi

# Pass through changer device if set
if [[ -n "$CHANGER_DEVICE" && -e "$CHANGER_DEVICE" ]]; then
    SD_CMD+=(--device "${CHANGER_DEVICE}:${CHANGER_DEVICE}")
fi

SD_CMD+=(
    -e "BAREOS_SD_PASSWORD=${SD_PASSWORD}"
    -v "${BAREOS_CONFIG_DIR}:/etc/bareos:ro"
    -v "${BAREOS_DATA_DIR}:/var/lib/bareos/storage:rw"
    "$SD_IMAGE"
)

# ── Start container ──────────────────────────────────────────────────────────
log "Starting bareos-sd container..."
"${SD_CMD[@]}"

# ── Make st load on boot ─────────────────────────────────────────────────────
log "Configuring st module to load at boot..."
echo "st" > /etc/modules-load.d/bareos-st.conf

# ── Persist container across reboots ─────────────────────────────────────────
cat > /etc/systemd/system/bareos-sd-docker.service <<EOF
[Unit]
Description=Bareos Storage Daemon (Docker)
After=docker.service
Requires=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a ${SD_CONTAINER}
ExecStop=/usr/bin/docker stop ${SD_CONTAINER}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bareos-sd-docker.service
log "systemd service enabled (bareos-sd-docker)"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
log "============================================"
log "  Tape Server Setup Complete"
log "============================================"
echo ""
echo "  Storage Daemon is running:"
echo "    docker ps | grep bareos-sd"
echo "    docker logs bareos-sd"
echo ""
echo "  Now on TrueNAS, run:"
echo "    midclt call tape_backup.bareos.setup"
echo ""
echo "  Config files: $BAREOS_CONFIG_DIR"
echo "  Data:         $BAREOS_DATA_DIR"
echo ""
echo "  To update: re-run this script with the same arguments."
echo ""
