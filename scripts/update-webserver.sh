#!/usr/bin/env bash
# update-webserver.sh — apt/dnf upgrade on every webserver entry in the inventory.
set -uo pipefail
LIB=/usr/local/lib/lib-update.sh
[[ -r $LIB ]] || LIB="$(dirname "$(readlink -f "$0")")/lib-update.sh"
# shellcheck source=lib-update.sh
source "$LIB"

LOG=$LOG_DIR_DEFAULT/webserver-$(date +%s).log
mkdir -p "$LOG_DIR_DEFAULT"
exec > >(tee -a "$LOG") 2>&1

require_root
log "starting webserver update"

while (( $# )); do
  case "$1" in --inventory) shift; INVENTORY=$1 ;; esac
  shift || true
done

UPGRADE_SCRIPT='set -e
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade
elif command -v dnf >/dev/null; then
  dnf -y upgrade
elif command -v yum >/dev/null; then
  yum -y update
else
  echo "no supported pkg manager" >&2; exit 64
fi
[ -f /var/run/reboot-required ] && echo NEEDS_REBOOT || true'

# Iterate webservers[*]
count=$(yqr '.webservers | length' 2>/dev/null)
[[ -z $count || $count == 0 ]] && { emit_json "webserver" "skipped" false "no webservers in inventory"; exit 0; }

results=()
i=0
while (( i < count )); do
  host=$(yqr ".webservers[$i].host")
  user=$(yqr ".webservers[$i].user"); user=${user:-root}
  key=$(yqr  ".webservers[$i].ssh_key"); key=${key:-/root/.ssh/update_id_ed25519}
  if [[ -z $host ]]; then i=$((i+1)); continue; fi
  log "upgrading webserver $user@$host"
  status="ok"; err=""; needs_reboot=false
  if out=$(ssh_target "$user" "$host" "$key" bash -s <<<"$UPGRADE_SCRIPT" 2>&1); then
    grep -q NEEDS_REBOOT <<<"$out" && needs_reboot=true
  else
    status="failed"; err="ssh/upgrade failed"
  fi
  results+=("$(emit_json "webserver-$host" "$status" "$needs_reboot" "$err")")
  i=$((i+1))
done

printf '%s\n' "${results[@]}"
fail=$(printf '%s\n' "${results[@]}" | jq -s '[.[]|select(.status=="failed")]|length')
emit_json "webserver" "$([ "$fail" = 0 ] && echo ok || echo failed)" false "$fail failures" \
  "$(jq -nc --arg log "$LOG" --argjson c "$(printf '%s\n' "${results[@]}" | jq -s .)" '{log:$log,children:$c}')"
[[ $fail -eq 0 ]]
