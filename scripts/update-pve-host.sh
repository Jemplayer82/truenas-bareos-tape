#!/usr/bin/env bash
# update-pve-host.sh — apt dist-upgrade the Proxmox host itself.
set -uo pipefail
LIB=/usr/local/lib/lib-update.sh
[[ -r $LIB ]] || LIB="$(dirname "$(readlink -f "$0")")/lib-update.sh"
# shellcheck source=lib-update.sh
source "$LIB"

LOG=$LOG_DIR_DEFAULT/pve-host-$(date +%s).log
mkdir -p "$LOG_DIR_DEFAULT"
exec > >(tee -a "$LOG") 2>&1

require_root
log "starting pve-host update"

err_msg=""; status="ok"; needs_reboot=false

if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
  status="failed"; err_msg="apt-get update failed"
elif ! DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confold \
        -o Dpkg::Options::=--force-confdef \
        dist-upgrade; then
  status="failed"; err_msg="dist-upgrade failed"
fi

[[ -f /var/run/reboot-required ]] && needs_reboot=true

emit_json "pve-host" "$status" "$needs_reboot" "$err_msg" \
  "$(jq -nc --arg log "$LOG" '{log:$log}')"
[[ $status == ok ]]
