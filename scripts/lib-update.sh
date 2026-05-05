# Shared helpers for the unattended update stack. Source me, don't run me.
# shellcheck shell=bash

NOTIFY_DEFAULT="jemplayer82@gmail.com"
LOG_DIR_DEFAULT="/var/log/update"
INVENTORY_DEFAULT="/etc/update/inventory.yaml"

ts()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '%s [Fred] %s\n' "$(ts)" "$*"; }
warn(){ printf '%s [Fred][warn] %s\n' "$(ts)" "$*" >&2; }
err() { printf '%s [Fred][error] %s\n' "$(ts)" "$*" >&2; }

# emit_json TARGET STATUS [needs_reboot=false] [error=""] [extra_json="{}"]
emit_json() {
  local target=$1 status=$2 needs_reboot=${3:-false} error=${4:-} extra=${5:-'{}'}
  jq -nc --arg t "$target" --arg s "$status" --arg e "$error" \
        --argjson nr "$needs_reboot" --argjson x "$extra" \
        '{target:$t,status:$s,needs_reboot:$nr,error:$e} * $x'
}

# yqr KEY [INVENTORY] — read a scalar via yq, prefers `yq` (mikefarah) then python.
yqr() {
  local key=$1 inv=${2:-${INVENTORY:-$INVENTORY_DEFAULT}}
  if command -v yq >/dev/null 2>&1; then
    yq -r "$key // \"\"" "$inv" 2>/dev/null
  else
    python3 -c "import sys,yaml,functools; d=yaml.safe_load(open('$inv')); \
ks='$key'.lstrip('.').split('.'); v=d
for k in ks:
    if v is None: break
    v=v.get(k) if isinstance(v,dict) else None
print('' if v is None else v)" 2>/dev/null
  fi
}

# yql KEY [INVENTORY] — read a list (one item per line).
yql() {
  local key=$1 inv=${2:-${INVENTORY:-$INVENTORY_DEFAULT}}
  if command -v yq >/dev/null 2>&1; then
    yq -r "$key[]?" "$inv" 2>/dev/null
  else
    python3 -c "import yaml; d=yaml.safe_load(open('$inv')); \
ks='$key'.lstrip('.').split('.'); v=d
for k in ks:
    if v is None: break
    v=v.get(k) if isinstance(v,dict) else None
if isinstance(v,list):
    [print(x) for x in v]" 2>/dev/null
  fi
}

ssh_target() {
  local user=$1 host=$2 key=$3; shift 3
  ssh -i "$key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 "$user@$host" "$@"
}

# health_ct ID [TIMEOUT_SECS=180]
health_ct() {
  local id=$1 t=${2:-180} deadline=$(( $(date +%s) + t )) s
  while (( $(date +%s) < deadline )); do
    if [[ $(pct status "$id" 2>/dev/null) == *running* ]]; then
      s=$(pct exec "$id" -- systemctl is-system-running 2>/dev/null || true)
      [[ $s == running || $s == degraded || $s == starting ]] && return 0
    fi
    sleep 5
  done
  return 1
}

# health_vm ID [TIMEOUT_SECS=180]
health_vm() {
  local id=$1 t=${2:-180} deadline=$(( $(date +%s) + t )) s
  while (( $(date +%s) < deadline )); do
    if [[ $(qm status "$id" 2>/dev/null) == *running* ]] \
        && qm agent "$id" ping >/dev/null 2>&1; then
      s=$(qm guest exec "$id" --timeout 10 -- systemctl is-system-running 2>/dev/null \
          | jq -r '.["out-data"] // empty' 2>/dev/null || true)
      s=${s%%[[:space:]]*}
      [[ $s == running || $s == degraded || $s == starting ]] && return 0
    fi
    sleep 5
  done
  return 1
}

# pbs_latest vm|ct ID
pbs_latest() {
  local kind=$1 id=$2 store
  store=$(yqr '.pbs.storage')
  [[ -z $store ]] && return 2
  pvesm list "$store" --content backup 2>/dev/null \
    | awk -v want="$kind/$id" '$1 ~ ":backup/"want"/" {print $1}' \
    | sort | tail -1
}

# pbs_safe vm|ct ID — latest archive that respects pbs.min_age_minutes.
pbs_safe() {
  local kind=$1 id=$2 min_min snap iso epoch now age
  min_min=$(yqr '.pbs.min_age_minutes'); min_min=${min_min:-60}
  snap=$(pbs_latest "$kind" "$id") || return 2
  [[ -z $snap ]] && return 2
  # Volid format: <store>:backup/<kind>/<id>/<datetime>
  iso=${snap##*/}; iso=${iso//T/ }
  epoch=$(date -d "$iso" +%s 2>/dev/null) || { echo "$snap"; return 0; }
  now=$(date +%s); age=$(( now - epoch ))
  (( age < min_min*60 )) && return 3
  echo "$snap"
}

restore_ct_from_pbs() {
  local id=$1 snap rc
  snap=$(pbs_safe ct "$id"); rc=$?
  (( rc != 0 )) && return $rc
  log "restoring CT $id from $snap"
  pct stop "$id" --skiplock 1 2>/dev/null || true
  pct restore "$id" "$snap" --force 1 || return 1
  pct start "$id" || return 1
  echo "$snap"
}

restore_vm_from_pbs() {
  local id=$1 snap rc
  snap=$(pbs_safe vm "$id"); rc=$?
  (( rc != 0 )) && return $rc
  log "restoring VM $id from $snap"
  qm stop "$id" 2>/dev/null || true
  qm destroy "$id" --purge 1 --skiplock 1 2>/dev/null || return 1
  qmrestore "$snap" "$id" --force 1 || return 1
  qm start "$id" || return 1
  echo "$snap"
}

require_root() { [[ $EUID -eq 0 ]] || { err "must run as root"; exit 1; }; }

mkdir -p "$LOG_DIR_DEFAULT" 2>/dev/null || true
