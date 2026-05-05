#!/usr/bin/env bash
# update-all.sh — top-level orchestrator. Runs every backend, aggregates JSON
# results, sends one summary email. Continues past per-target failures.
set -uo pipefail
LIB=/usr/local/lib/lib-update.sh
[[ -r $LIB ]] || LIB="$(dirname "$(readlink -f "$0")")/lib-update.sh"
# shellcheck source=lib-update.sh
source "$LIB"

INVENTORY=${INVENTORY:-$INVENTORY_DEFAULT}
NOTIFY=${NOTIFY:-$NOTIFY_DEFAULT}
NO_RESTORE=0; DRY_RUN=0; SECURITY_ONLY=0
ONLY=()

usage() {
  cat <<EOF
update-all.sh — Fred's unattended infrastructure updater.

Options:
  --only TARGET[,TARGET...]   pve-host, pve-lxc, pve-vms, truenas-docker, webserver,
                              or specific ids (vm-101, ct-204)
  --inventory FILE            default $INVENTORY_DEFAULT
  --notify EMAIL              default $NOTIFY_DEFAULT
  --no-restore                skip auto-rollback
  --security-only             pass through to backend OS upgraders (where supported)
  --dry-run                   show what would run, do nothing
EOF
}

while (( $# )); do
  case "$1" in
    --only)         shift; IFS=',' read -ra ONLY <<<"$1" ;;
    --inventory)    shift; INVENTORY=$1 ;;
    --notify)       shift; NOTIFY=$1 ;;
    --no-restore)   NO_RESTORE=1 ;;
    --security-only) SECURITY_ONLY=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done

require_root

LOG_DIR=$LOG_DIR_DEFAULT
mkdir -p "$LOG_DIR"
RUN_LOG=$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$RUN_LOG") 2>&1
log "starting update-all (inventory=$INVENTORY notify=$NOTIFY)"

run_target() {
  local name=$1; shift
  if (( ${#ONLY[@]} )); then
    local match=0 x
    for x in "${ONLY[@]}"; do
      [[ $x == "$name" ]] && match=1
      # also allow vm-/ct- ids to imply pve-vms/pve-lxc
      [[ $x == vm-* && $name == pve-vms ]] && match=1
      [[ $x == ct-* && $name == pve-lxc ]] && match=1
    done
    (( match )) || { log "skip $name (not in --only)"; return 0; }
  fi
  log "▶ $name"
  if (( DRY_RUN )); then
    log "DRY: $*"
    return 0
  fi
  local out
  out=$("$@" 2>&1) || true
  # Last line of stdout is the per-target rollup JSON record.
  printf '%s\n' "$out"
  printf '%s\n' "$out" | tail -1
}

results_file=$(mktemp)
trap 'rm -f "$results_file"' EXIT

extra_args=()
(( NO_RESTORE )) && extra_args+=(--no-restore)
inv_args=(--inventory "$INVENTORY")

# Capture last-line JSON per target
collect() {
  local out=$1
  printf '%s\n' "$out" | tail -1 >> "$results_file"
}

if (( DRY_RUN == 0 )); then
  out=$(/usr/local/sbin/update-pve-host.sh        2>&1 || true); printf '%s\n' "$out"; collect "$out"
  out=$(/usr/local/sbin/update-pve-lxc.sh         "${inv_args[@]}" "${extra_args[@]}" 2>&1 || true); printf '%s\n' "$out"; collect "$out"
  out=$(/usr/local/sbin/update-pve-vms.sh         "${inv_args[@]}" "${extra_args[@]}" 2>&1 || true); printf '%s\n' "$out"; collect "$out"
  out=$(/usr/local/sbin/update-truenas-docker.sh  "${inv_args[@]}" "${extra_args[@]}" 2>&1 || true); printf '%s\n' "$out"; collect "$out"
  out=$(/usr/local/sbin/update-webserver.sh       "${inv_args[@]}" 2>&1 || true); printf '%s\n' "$out"; collect "$out"
else
  log "DRY RUN — listing what would be touched:"
  pct list 2>/dev/null || true
  qm list  2>/dev/null || true
  echo "[]" > "$results_file"
fi

# Aggregate — one JSON line per backend rollup
summary=$(jq -s '.' "$results_file" 2>/dev/null || echo '[]')
failures=$(jq '[.[]|select(.status=="failed" or .status=="restore_failed" or .status=="unhealthy_no_backup" or .status=="unhealthy_no_snapshot")]|length' <<<"$summary")
rollbacks=$(jq '[.[]|select(.status=="restored_from_backup" or .status=="restored_from_zfs_snapshot" or .status=="rolled_back")]|length' <<<"$summary")
needs_reboot=$(jq '[.[]|select(.needs_reboot==true)|.target]' <<<"$summary")

subj="[Fred] update OK on $(hostname)"
(( rollbacks > 0 )) && subj="[Fred] update OK with rollbacks on $(hostname)"
(( failures > 0 ))  && subj="[Fred] update FAILED ($failures) on $(hostname)"

NOTIFY_TOOL=/usr/local/sbin/notify-email.sh
[[ -x $NOTIFY_TOOL ]] || NOTIFY_TOOL="$(dirname "$(readlink -f "$0")")/notify-email.sh"

{ echo "Run log: $RUN_LOG"
  echo "Inventory: $INVENTORY"
  echo
  echo "Summary:"; jq . <<<"$summary"
  echo
  echo "Needs reboot: $needs_reboot"
  echo
  echo "--- last 200 lines of run log ---"
  tail -n 200 "$RUN_LOG"
} | "$NOTIFY_TOOL" "$NOTIFY" "$subj" - || warn "notify-email failed (msmtp configured?)"

exit $(( failures > 0 ? 1 : 0 ))
