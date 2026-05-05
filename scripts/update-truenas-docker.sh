#!/usr/bin/env bash
# update-truenas-docker.sh — SSH to TrueNAS and run update-containers.sh.
# On persistent unhealthy, optionally zfs-rollback configured datasets to the
# latest pre-run periodic snapshot (TrueNAS uses ZFS snapshots, not PBS).
set -uo pipefail
LIB=/usr/local/lib/lib-update.sh
[[ -r $LIB ]] || LIB="$(dirname "$(readlink -f "$0")")/lib-update.sh"
# shellcheck source=lib-update.sh
source "$LIB"

LOG=$LOG_DIR_DEFAULT/truenas-docker-$(date +%s).log
mkdir -p "$LOG_DIR_DEFAULT"
exec > >(tee -a "$LOG") 2>&1

require_root
log "starting truenas-docker update"

NO_RESTORE=0
while (( $# )); do
  case "$1" in
    --inventory) shift; INVENTORY=$1 ;;
    --no-restore) NO_RESTORE=1 ;;
  esac
  shift || true
done

HOST=$(yqr '.truenas.host')
USER=$(yqr '.truenas.user'); USER=${USER:-root}
KEY=$(yqr '.truenas.ssh_key'); KEY=${KEY:-/root/.ssh/update_id_ed25519}
RSCRIPT=$(yqr '.truenas.remote_script'); RSCRIPT=${RSCRIPT:-/usr/local/sbin/update-containers.sh}
NOTIFY=${NOTIFY:-$NOTIFY_DEFAULT}

if [[ -z $HOST ]]; then
  emit_json "truenas-docker" "skipped" false "no truenas.host in inventory"
  exit 0
fi

status="ok"; err=""; extra='{}'

log "running $RSCRIPT on $USER@$HOST"
out_json=""
if out=$(ssh_target "$USER" "$HOST" "$KEY" "sudo $RSCRIPT --notify $NOTIFY --prune" 2>&1); then
  out_json=$(printf '%s\n' "$out" | tail -1)
else
  rc=$?
  out_json=$(printf '%s\n' "$out" | tail -1)
  log "remote update-containers.sh exited $rc"
  if [[ $rc -ne 0 ]]; then status="failed"; err="remote exit $rc"; fi
fi

# Optional ZFS rollback if remote reported unhealthy/restore_failed
remote_status=$(jq -r '.status // empty' <<<"$out_json" 2>/dev/null || true)
if [[ $NO_RESTORE -eq 0 && ( $remote_status == restore_failed || $status == failed ) ]]; then
  enabled=$(yqr '.truenas.zfs_rollback.enabled')
  if [[ $enabled == true ]]; then
    log "attempting truenas zfs rollback"
    min_min=$(yqr '.truenas.zfs_rollback.min_age_minutes'); min_min=${min_min:-30}
    max_days=$(yqr '.truenas.zfs_rollback.max_age_days');   max_days=${max_days:-7}
    rolled=()
    while read -r ds; do
      [[ -z $ds ]] && continue
      log "rolling back $ds"
      remote_cmd=$(cat <<EOF
ds='$ds'; min=$min_min; max=$max_days
now=\$(date +%s)
snap=\$(zfs list -t snapshot -H -o name,creation -p "\$ds" 2>/dev/null | \
  awk -v now="\$now" -v min="\$min" -v max="\$max" '
    { age = now - \$2; if (age >= min*60 && age <= max*86400) print \$2"\t"\$1 }' | \
  sort -n | tail -1 | cut -f2)
[ -z "\$snap" ] && { echo NO_SAFE_SNAPSHOT; exit 3; }
zfs rollback -r "\$snap" && echo "ROLLED_BACK \$snap"
EOF
)
      if r=$(ssh_target "$USER" "$HOST" "$KEY" "$remote_cmd" 2>&1); then
        snap=$(awk '/^ROLLED_BACK/ {print $2}' <<<"$r")
        rolled+=("$ds@$snap")
      else
        log "zfs rollback failed for $ds: $r"
      fi
    done < <(yql '.truenas.zfs_rollback.datasets')

    if (( ${#rolled[@]} )); then
      status="restored_from_zfs_snapshot"; err=""
      extra=$(jq -nc --argjson r "$(printf '%s\n' "${rolled[@]}" | jq -R . | jq -s .)" '{rolled:$r}')
    else
      status="unhealthy_no_snapshot"; err="no eligible zfs snapshot"
    fi
  fi
fi

emit_json "truenas-docker" "$status" false "$err" \
  "$(jq -nc --arg log "$LOG" --argjson r "$(jq -nc 'try fromjson catch null' <<<"$out_json" 2>/dev/null || echo null)" --argjson x "$extra" '{log:$log,remote:$r} * $x')"
[[ $status == ok || $status == restored_from_zfs_snapshot ]]
