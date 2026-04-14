#!/usr/bin/env bash
set -euo pipefail

# TrueNAS SCALE - Bareos Tape Archival Plugin Installer
# Installs Bareos daemons, tape tools, middleware plugin, and webui components
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Jemplayer82/truenas-bareos-tape/main/install/install.sh | sudo bash

GITHUB_REPO="https://github.com/Jemplayer82/truenas-bareos-tape"
GITHUB_RAW="https://raw.githubusercontent.com/Jemplayer82/truenas-bareos-tape/main"
INSTALL_DIR="${HOME}/truenas-bareos-tape"
MIDDLEWARE_PLUGIN_DIR="/usr/lib/python3/dist-packages/middlewared/plugins/tape_backup"
BAREOS_REPO_KEY="https://download.bareos.org/current/xUbuntu_22.04/Release.key"
BAREOS_REPO="deb https://download.bareos.org/current/xUbuntu_22.04/ /"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

if ! grep -qi 'truenas\|debian' /etc/os-release 2>/dev/null; then
    warn "This does not appear to be a TrueNAS SCALE or Debian system"
fi

log "Starting Bareos Tape Archival installation on TrueNAS SCALE"

# --- Step 0: Download/update plugin files from GitHub ---
log "Fetching latest plugin files from GitHub..."
if command -v git &>/dev/null; then
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Updating existing installation from GitHub..."
        git -C "$INSTALL_DIR" pull --ff-only
    else
        log "Cloning from GitHub to $INSTALL_DIR..."
        git clone --depth=1 "$GITHUB_REPO" "$INSTALL_DIR"
    fi
else
    # No git — download as tarball
    log "git not found, downloading release tarball from GitHub..."
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$GITHUB_REPO/archive/refs/heads/main.tar.gz" \
        | tar -xz --strip-components=1 -C "$INSTALL_DIR"
fi
log "Plugin files downloaded to $INSTALL_DIR"

# Use the downloaded copy as the project source
PROJECT_DIR="$INSTALL_DIR"

# --- Step 1: Enable apt if restricted ---
log "Checking package manager availability..."
if [[ ! -x /usr/bin/apt-get ]]; then
    warn "apt-get is not executable (TrueNAS appliance restriction)"
    warn "Attempting to enable temporarily for installation..."
    if [[ -f /usr/bin/apt-get ]]; then
        chmod +x /usr/bin/apt-get /usr/bin/apt /usr/bin/dpkg 2>/dev/null || true
    else
        error "Cannot find apt-get. Manual package installation required."
    fi
fi

# --- Step 2: Add Bareos repository ---
log "Adding Bareos apt repository..."
if [[ ! -f /etc/apt/sources.list.d/bareos.list ]]; then
    curl -fsSL "$BAREOS_REPO_KEY" | gpg --dearmor -o /etc/apt/trusted.gpg.d/bareos-keyring.gpg
    echo "$BAREOS_REPO" > /etc/apt/sources.list.d/bareos.list
    apt-get update -qq
else
    log "Bareos repository already configured"
fi

# --- Step 3: Install Bareos packages ---
log "Installing Bareos packages..."
BAREOS_PACKAGES=(
    bareos-director
    bareos-storage
    bareos-storage-tape
    bareos-filedaemon
    bareos-database-postgresql
    bareos-bconsole
    bareos-database-tools
    bareos-tools
)

apt-get install -y -qq "${BAREOS_PACKAGES[@]}" 2>/dev/null || {
    warn "Some Bareos packages may have failed. Continuing..."
}

# --- Step 4: Install tape utilities ---
log "Installing tape utilities..."
TAPE_PACKAGES=(
    mt-st
    mtx
    sg3-utils
    lsscsi
)

apt-get install -y -qq "${TAPE_PACKAGES[@]}" 2>/dev/null || {
    warn "Some tape utility packages may have failed. Continuing..."
}

# --- Step 5: Install python-bareos ---
log "Installing python-bareos..."
pip3 install python-bareos 2>/dev/null || {
    apt-get install -y -qq python3-bareos 2>/dev/null || {
        warn "python-bareos installation failed. Install manually: pip3 install python-bareos"
    }
}

# --- Step 6: Install Jinja2 if not present ---
log "Ensuring Jinja2 is available..."
python3 -c "import jinja2" 2>/dev/null || {
    pip3 install jinja2 2>/dev/null || {
        apt-get install -y -qq python3-jinja2 2>/dev/null || true
    }
}

# --- Step 7: Setup PostgreSQL for Bareos ---
log "Setting up PostgreSQL for Bareos catalog..."
if systemctl is-active --quiet postgresql; then
    # Create bareos database user and database if they don't exist
    su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='bareos'\" | grep -q 1" 2>/dev/null || {
        su - postgres -c "createuser -s bareos" 2>/dev/null || true
    }
    su - postgres -c "psql -lqt | cut -d'|' -f1 | grep -qw bareos" 2>/dev/null || {
        su - postgres -c "createdb -O bareos bareos" 2>/dev/null || true
    }

    # Run Bareos database initialization scripts
    if [[ -x /usr/lib/bareos/scripts/create_bareos_database ]]; then
        /usr/lib/bareos/scripts/create_bareos_database postgresql 2>/dev/null || true
        /usr/lib/bareos/scripts/make_bareos_tables postgresql 2>/dev/null || true
        /usr/lib/bareos/scripts/grant_bareos_privileges postgresql 2>/dev/null || true
        log "Bareos database initialized"
    fi
else
    warn "PostgreSQL is not running. Database initialization deferred to first setup."
fi

# --- Step 8: Install middleware plugin ---
log "Installing TrueNAS middleware plugin..."
mkdir -p "$MIDDLEWARE_PLUGIN_DIR"
cp -r "$PROJECT_DIR/middleware/plugins/tape_backup/"* "$MIDDLEWARE_PLUGIN_DIR/"
chmod -R 644 "$MIDDLEWARE_PLUGIN_DIR/"*.py
chmod 755 "$MIDDLEWARE_PLUGIN_DIR"
chmod 755 "$MIDDLEWARE_PLUGIN_DIR/config_templates"
chmod 644 "$MIDDLEWARE_PLUGIN_DIR/config_templates/"*.j2

log "Middleware plugin installed to $MIDDLEWARE_PLUGIN_DIR"

# --- Step 9: Run database migration ---
log "Running database migration..."
python3 -c "
import asyncio
import sys
sys.path.insert(0, '$MIDDLEWARE_PLUGIN_DIR')
# Migration will be run by middlewared on restart
print('Migration will execute when middlewared restarts')
"

# --- Step 10: Configure Bareos directories ---
log "Setting up Bareos configuration directories..."
for dir in bareos-dir.d bareos-sd.d bareos-fd.d; do
    mkdir -p "/etc/bareos/$dir"
done

# Create subdirectories for director config
for subdir in director catalog storage client console profile pool schedule messages job fileset; do
    mkdir -p "/etc/bareos/bareos-dir.d/$subdir"
done

# Create subdirectories for storage daemon config
for subdir in director storage device autochanger messages; do
    mkdir -p "/etc/bareos/bareos-sd.d/$subdir"
done

# Create subdirectories for file daemon config
for subdir in director client messages; do
    mkdir -p "/etc/bareos/bareos-fd.d/$subdir"
done

chown -R bareos:bareos /etc/bareos
chmod -R 750 /etc/bareos

# --- Step 11: Stop default Bareos services (will be managed by plugin) ---
log "Disabling default Bareos autostart (managed by middleware plugin)..."
systemctl disable bareos-dir bareos-sd bareos-fd 2>/dev/null || true
systemctl stop bareos-dir bareos-sd bareos-fd 2>/dev/null || true

# --- Step 12: Restart middlewared ---
log "Restarting TrueNAS middleware to load tape_backup plugin..."
systemctl restart middlewared 2>/dev/null || {
    warn "Could not restart middlewared. You may need to reboot or restart manually."
}

# --- Step 13: Print WebUI integration instructions ---
echo ""
log "============================================"
log "  Bareos Tape Archival - Installation Complete"
log "============================================"
echo ""
echo "  Middleware plugin installed. After middlewared restarts:"
echo ""
echo "  1. SSH into TrueNAS and run initial setup:"
echo "     midclt call tape_backup.bareos.setup"
echo ""
echo "  2. Check detected tape drives:"
echo "     midclt call tape_backup.drive.query"
echo ""
echo "  3. Check Bareos service status:"
echo "     midclt call tape_backup.bareos.status"
echo ""
echo "  To update to the latest version, re-run the installer:"
echo "     curl -fsSL https://raw.githubusercontent.com/Jemplayer82/truenas-bareos-tape/main/install/install.sh | sudo bash"
echo ""
echo "  WebUI components must be integrated into the TrueNAS"
echo "  Angular build separately. See README.md for details."
echo ""
echo "  Bareos packages installed:"
for pkg in "${BAREOS_PACKAGES[@]}"; do
    echo "    - $pkg"
done
echo ""
echo "  Tape tools installed:"
for pkg in "${TAPE_PACKAGES[@]}"; do
    echo "    - $pkg"
done
echo ""
