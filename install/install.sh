#!/usr/bin/env bash
set -euo pipefail

# TrueNAS SCALE — Bareos Tape Archival: Middleware & WebUI Installer
#
# This script installs the TrueNAS middleware plugin and Angular UI components.
# It does NOT manage Docker containers — those are handled by the TrueNAS app.
#
# Prerequisites:
#   1. Install the "Bareos Tape Archival" app from the TrueNAS App Catalog first.
#   2. Run this script to activate native GUI integration.
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Jemplayer82/truenas-bareos-tape/main/install/install.sh | sudo bash

GITHUB_REPO="https://github.com/Jemplayer82/truenas-bareos-tape"
MIDDLEWARE_PLUGIN_DIR="/usr/lib/python3/dist-packages/middlewared/plugins/tape_backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# --- Pre-flight ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    REAL_HOME="$HOME"
fi
INSTALL_DIR="${REAL_HOME}/truenas-bareos-tape"

log "Bareos Tape Archival — Middleware Installer"
log "============================================"

# --- Step 1: Check Docker (app must be installed first) ---
log "Checking Docker..."
if ! command -v docker &>/dev/null; then
    error "Docker is not available. TrueNAS SCALE 24.10+ is required."
fi
docker info &>/dev/null || error "Docker daemon is not running or not accessible."

if ! docker inspect bareos-dir &>/dev/null; then
    warn "The bareos-dir container was not found."
    warn "Install the 'Bareos Tape Archival' app from the TrueNAS App Catalog first."
    warn "Continuing anyway — run 'midclt call tape_backup.bareos.setup' after starting the app."
fi
log "Docker OK"

# --- Step 2: Download plugin files from GitHub ---
log "Fetching plugin files from GitHub..."
if command -v git &>/dev/null; then
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Updating existing installation..."
        git -C "$INSTALL_DIR" pull --ff-only
    else
        log "Cloning to $INSTALL_DIR..."
        git clone --depth=1 "$GITHUB_REPO" "$INSTALL_DIR"
    fi
else
    log "git not found — downloading tarball..."
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$GITHUB_REPO/archive/refs/heads/main.tar.gz" \
        | tar -xz --strip-components=1 -C "$INSTALL_DIR"
fi
log "Plugin files ready at $INSTALL_DIR"

# --- Step 3: Install python-bareos ---
log "Installing python-bareos..."
python3 -m pip install python-bareos jinja2 --quiet 2>/dev/null || {
    warn "pip install failed — trying pip3..."
    pip3 install python-bareos jinja2 --quiet 2>/dev/null || {
        warn "python-bareos install failed. Run manually: pip3 install python-bareos jinja2"
    }
}

# --- Step 4: Install middleware plugin ---
log "Installing TrueNAS middleware plugin..."
mkdir -p "$MIDDLEWARE_PLUGIN_DIR"
cp -r "$INSTALL_DIR/middleware/plugins/tape_backup/"* "$MIDDLEWARE_PLUGIN_DIR/"
find "$MIDDLEWARE_PLUGIN_DIR" -name "*.py" -exec chmod 644 {} \;
find "$MIDDLEWARE_PLUGIN_DIR" -name "*.j2" -exec chmod 644 {} \;
chmod 755 "$MIDDLEWARE_PLUGIN_DIR"
chmod 755 "$MIDDLEWARE_PLUGIN_DIR/config_templates"
log "Middleware plugin installed to $MIDDLEWARE_PLUGIN_DIR"

# --- Step 5: Create Bareos data directories ---
log "Creating Bareos data directories..."
mkdir -p /mnt/bareos/{config,data,logs}
mkdir -p /mnt/bareos/data/{postgres,director,storage}

# --- Step 6: Restart middlewared ---
log "Restarting TrueNAS middleware to load tape_backup plugin..."
systemctl restart middlewared 2>/dev/null && log "middlewared restarted" || {
    warn "Could not restart middlewared automatically."
    warn "Run: systemctl restart middlewared"
}

# --- Done ---
echo ""
log "============================================"
log "  Bareos Tape Archival — Install Complete"
log "============================================"
echo ""
echo "  Next steps:"
echo ""
echo "  1. If not already done, install the 'Bareos Tape Archival' app"
echo "     from the TrueNAS App Catalog and start it."
echo ""
echo "  2. Run initial setup (after the app containers are running):"
echo "     midclt call tape_backup.bareos.setup"
echo ""
echo "  3. Verify tape drive detection:"
echo "     midclt call tape_backup.drive.query"
echo ""
echo "  4. Check container status:"
echo "     midclt call tape_backup.bareos.status"
echo "     docker ps | grep bareos"
echo ""
echo "  5. Open TrueNAS WebUI → Data Protection → Tape Backup"
echo ""
echo "  To update:"
echo "     git -C $INSTALL_DIR pull && sudo $INSTALL_DIR/install/install.sh"
echo ""
echo "  Bareos data lives in: /mnt/bareos/"
echo ""
