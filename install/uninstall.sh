#!/usr/bin/env bash
set -euo pipefail

# TrueNAS SCALE - Bareos Tape Archival Plugin Uninstaller

MIDDLEWARE_PLUGIN_DIR="/usr/lib/python3/dist-packages/middlewared/plugins/tape_backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

echo ""
warn "This will remove the Bareos Tape Archival plugin from TrueNAS."
warn "Bareos catalog database and configuration will be preserved."
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Stop Bareos services ---
log "Stopping Bareos services..."
systemctl stop bareos-dir bareos-sd bareos-fd 2>/dev/null || true
systemctl disable bareos-dir bareos-sd bareos-fd 2>/dev/null || true

# --- Remove middleware plugin ---
log "Removing middleware plugin..."
if [[ -d "$MIDDLEWARE_PLUGIN_DIR" ]]; then
    rm -rf "$MIDDLEWARE_PLUGIN_DIR"
    log "Removed $MIDDLEWARE_PLUGIN_DIR"
else
    warn "Middleware plugin directory not found"
fi

# --- Restart middlewared ---
log "Restarting TrueNAS middleware..."
systemctl restart middlewared 2>/dev/null || {
    warn "Could not restart middlewared. You may need to reboot."
}

echo ""
log "============================================"
log "  Bareos Tape Archival - Uninstall Complete"
log "============================================"
echo ""
echo "  The middleware plugin has been removed."
echo ""
echo "  The following are preserved (remove manually if desired):"
echo "    - Bareos packages (apt remove bareos-*)"
echo "    - Bareos configuration (/etc/bareos/)"
echo "    - Bareos catalog database (PostgreSQL: bareos)"
echo "    - Tape tools (mt-st, mtx, sg3-utils, lsscsi)"
echo "    - Bareos apt repository (/etc/apt/sources.list.d/bareos.list)"
echo ""
echo "  To fully remove Bareos packages:"
echo "    apt remove --purge bareos-director bareos-storage bareos-filedaemon \\"
echo "      bareos-database-postgresql bareos-bconsole bareos-tools"
echo ""
echo "  To remove the catalog database:"
echo "    su - postgres -c 'dropdb bareos; dropuser bareos'"
echo ""
