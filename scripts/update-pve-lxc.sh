#!/usr/bin/env bash
# update-pve-lxc.sh — upgrade every running LXC, health-check, retry once,
# fall back to PBS restore on persistent failure.
set -uo pipefail
LIB=/usr/local/lib/lib-update.sh
[[ -r $LIB ]] || LIB="$(dirname "$(readlink -f "$0")")/lib-update.sh"
# shellcheck source=lib-update.sh
source "$LIB"

LOG=$LOG_DIR_DEFAULT/pve-lxc-$(date +%s).log
mkdir -p "$LOG_DIR_DEFAULT"
exec > >(tee -a "$LOG") 2>&1

require_root
log "starting pve-lxc update"

ONLY=()
while (( $# )); do
  case "$1" in
    --inventory) shift; INVENTORY=$1 ;;
    --only)      shift; IFS=',' read -ra ONLY <<<"$1" ;;
    --no-restore) NO_RESTORE=1 ;;
    *) ;;
  esac
  shift || true
done
NO_RESTORE=${NO_RESTORE:-0}

want_id() {
  (( ${#ONLY[@]} == 0 )) && return 0
  local id=$1 x
  for x in "${ONLY[@]}"; do [[ $x == "$id" || $x == "ct-$id" ]] && return 0; done
  return 1
}

upgrade_one() {  # echoes JSON record on stdout
  local id=$1 status="ok" err="" extra='{}'
  local pm needs_reboot=false snap

  if ! pct status "$id" 2>/dev/null | grep -q running; then
    emit_json "ct-$id" "skipped" false "not running"; return 0
  fi

  pm=$(pct exec "$id" -- sh -c 'command -v apt-get||command -v dnf||command -v yum||true' 2>/dev/null | tr -d '\r')
  if [[ -z $pm ]]; then
    emit_json "ct-$id" "skipped" false "no supported package manager"; return 0
  fi

  log "ct-$id: upgrading via $pm"
  case "$pm" in
    */apt-get) pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive "$pm" update \
              && pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive "$pm" -y \
                   -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade \
              || { status="failed"; err="apt upgrade failed"; } ;;
    */dnf|*/yum) pct exec "$id" -- "$pm" -y upgrade \
              || { status="failed"; err="$pm upgrade failed"; } ;;
  esac

  if [[ $status == ok ]]; then
    if pct exec "$id" -- test -f /var/run/reboot-required 2>/dev/null; then
      needs_reboot=true
    fi
    if ! health_ct "$id" 180; then
      log "ct-$id: unhealthy, attempting one reboot"
      pct reboot "$id" 2>/dev/null || true
      if ! health_ct "$id" 180; then
        status="unhealthy"
        err="unhealthy after reboot retry"
      fi
    fi
  fi

  if [[ $status == unhealthy && $NO_RESTORE -eq 0 ]]; then
    if snap=$(restore_ct_from_pbs "$id"); then
      if health_ct "$id" 180; then
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

  emit_json "ct-$id" "$status" "$needs_reboot" "$err" "$extra"
}

mapfile -t ids < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
results=()
for id in "${ids[@]}"; do
  want_id "$id" || continue
  results+=("$(upgrade_one "$id")")
done

# Rollup: emit one JSON per CT (orchestrator parses last line as group summary)
printf '%s\n' "${results[@]}"
fail=$(printf '%s\n' "${results[@]}" | jq -s '[.[]|select(.status=="failed" or .status=="unhealthy" or .status=="unhealthy_no_backup" or .status=="restore_failed")]|length')
emit_json "pve-lxc" "$([ "$fail" = 0 ] && echo ok || echo failed)" false "$fail failures" \
  "$(jq -nc --arg log "$LOG" --argjson c "$(printf '%s\n' "${results[@]}" | jq -s .)" '{log:$log,children:$c}')"
[[ $fail -eq 0 ]]
