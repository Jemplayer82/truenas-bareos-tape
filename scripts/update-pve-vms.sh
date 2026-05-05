#!/usr/bin/env bash
# update-pve-vms.sh — upgrade every running VM via qemu-guest-agent (preferred)
# or SSH fallback. Health-check, one reboot retry, PBS restore on persistent fail.
set -uo pipefail
LIB=/usr/local/lib/lib-update.sh
[[ -r $LIB ]] || LIB="$(dirname "$(readlink -f "$0")")/lib-update.sh"
# shellcheck source=lib-update.sh
source "$LIB"

LOG=$LOG_DIR_DEFAULT/pve-vms-$(date +%s).log
mkdir -p "$LOG_DIR_DEFAULT"
exec > >(tee -a "$LOG") 2>&1

require_root
log "starting pve-vms update"

ONLY=(); NO_RESTORE=0
while (( $# )); do
  case "$1" in
    --inventory) shift; INVENTORY=$1 ;;
    --only)      shift; IFS=',' read -ra ONLY <<<"$1" ;;
    --no-restore) NO_RESTORE=1 ;;
  esac
  shift || true
done

want_id() {
  (( ${#ONLY[@]} == 0 )) && return 0
  local id=$1 x
  for x in "${ONLY[@]}"; do [[ $x == "$id" || $x == "vm-$id" ]] && return 0; done
  return 1
}

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

upgrade_one() {
  local id=$1 status="ok" err="" extra='{}' needs_reboot=false snap out

  if ! qm status "$id" 2>/dev/null | grep -q running; then
    emit_json "vm-$id" "skipped" false "not running"; return 0
  fi

  if qm agent "$id" ping >/dev/null 2>&1; then
    log "vm-$id: upgrading via guest-agent"
    if out=$(qm guest exec "$id" --timeout 1800 --pass-stdin -- bash 2>&1 <<<"$UPGRADE_SCRIPT"); then
      grep -q NEEDS_REBOOT <<<"$out" && needs_reboot=true
    else
      status="failed"; err="guest-exec upgrade failed"
    fi
  else
    log "vm-$id: no guest-agent, skipping (configure SSH inventory entry to update)"
    emit_json "vm-$id" "skipped" false "no guest-agent and no SSH inventory entry"
    return 0
  fi

  if [[ $status == ok ]] && ! health_vm "$id" 180; then
    log "vm-$id: unhealthy, attempting one reboot"
    qm reboot "$id" 2>/dev/null || qm shutdown "$id" --forceStop 1 --timeout 60 2>/dev/null
    qm start "$id" 2>/dev/null || true
    if ! health_vm "$id" 240; then
      status="unhealthy"; err="unhealthy after reboot retry"
    fi
  fi

  if [[ $status == unhealthy && $NO_RESTORE -eq 0 ]]; then
    if snap=$(restore_vm_from_pbs "$id"); then
      if health_vm "$id" 240; then
        status="restored_from_backup"; err=""
        extra=$(jq -nc --arg s "$snap" '{restored_from:$s}')
      else
        status="restore_failed"; err="restored but still unhealthy"
      fi
    else
      rc=$?
      case $rc in
        2) status="unhealthy_no_backup"; err="no PBS archive found" ;;
        3) status="unhealthy_no_backup"; err="latest PBS archive too fresh (min_age_minutes)" ;;
        *) status="restore_failed"; err="restore command failed" ;;
      esac
    fi
  fi

  emit_json "vm-$id" "$status" "$needs_reboot" "$err" "$extra"
}

mapfile -t ids < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
results=()
for id in "${ids[@]}"; do
  want_id "$id" || continue
  results+=("$(upgrade_one "$id")")
done

printf '%s\n' "${results[@]}"
fail=$(printf '%s\n' "${results[@]}" | jq -s '[.[]|select(.status=="failed" or .status=="unhealthy" or .status=="unhealthy_no_backup" or .status=="restore_failed")]|length')
emit_json "pve-vms" "$([ "$fail" = 0 ] && echo ok || echo failed)" false "$fail failures" \
  "$(jq -nc --arg log "$LOG" --argjson c "$(printf '%s\n' "${results[@]}" | jq -s .)" '{log:$log,children:$c}')"
[[ $fail -eq 0 ]]
