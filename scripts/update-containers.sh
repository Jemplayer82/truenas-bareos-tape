#!/usr/bin/env bash
# update-containers.sh — pull latest images and recreate all running containers.
#
# Unattended: never prompts. Captures previous image digests so a failed pull or
# unhealthy container can be rolled back to its prior state. Logs to
# /var/log/container-update.log and emails on failure when --notify is set.
#
# Flags:
#   -a, --all                 include stopped containers too
#   -n, --name NAME [NAME...] only these containers/projects
#       --notify EMAIL        email this address on failure (uses notify-email.sh)
#       --log FILE            log file (default /var/log/container-update.log)
#       --health-timeout SECS wait this long for healthy/running (default 120)
#       --no-rollback         skip image rollback on failure
#       --prune               docker image prune -f after a successful run
#       --dry-run             print, don't run
#   -h, --help
#
# Exit codes: 0 ok, 1 failures all rolled back ok, 2 failures + rollback failed.

set -uo pipefail

DRY_RUN=0; INCLUDE_STOPPED=0; PRUNE=0; ROLLBACK=1
NOTIFY=""; HEALTH_TIMEOUT=120
LOG=/var/log/container-update.log
STATE_DIR=/var/lib/container-update
FILTER=()

while (( $# )); do
  case "$1" in
    -a|--all)            INCLUDE_STOPPED=1 ;;
    -n|--name)           shift; while (( $# )) && [[ $1 != -* ]]; do FILTER+=("$1"); shift; done; continue ;;
    --notify)            shift; NOTIFY=$1 ;;
    --log)               shift; LOG=$1 ;;
    --health-timeout)    shift; HEALTH_TIMEOUT=$1 ;;
    --no-rollback)       ROLLBACK=0 ;;
    --prune)             PRUNE=1 ;;
    --dry-run)           DRY_RUN=1 ;;
    -h|--help)           sed -n '2,22p' "$0"; exit 0 ;;
    *)                   echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift || true
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null || true
: > /dev/null  # touch shell
exec > >(awk -v log="$LOG" '{ts=strftime("%Y-%m-%dT%H:%M:%S%z"); printf "%s [Fred][docker] %s\n",ts,$0 | "tee -a "log}') 2>&1

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*"; }
run()  { if (( DRY_RUN )); then printf 'DRY: %s\n' "$*"; else eval "$@"; fi; }

command -v docker >/dev/null || { err "docker not found in PATH"; exit 2; }
command -v jq >/dev/null     || { err "jq required"; exit 2; }

NOTIFY_TOOL="$(dirname "$(readlink -f "$0")")/notify-email.sh"
[[ -x $NOTIFY_TOOL ]] || NOTIFY_TOOL=/usr/local/sbin/notify-email.sh

STATE_FILE="$STATE_DIR/state-$(date +%s).json"
echo '[]' > "$STATE_FILE"

state_append() {  # JSON-merge a single record into the state array
  local rec=$1 tmp; tmp=$(mktemp)
  jq --argjson r "$rec" '. + [$r]' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

in_filter() {
  (( ${#FILTER[@]} == 0 )) && return 0
  local needle=$1 f
  for f in "${FILTER[@]}"; do [[ $f == "$needle" ]] && return 0; done
  return 1
}

wait_healthy() {  # wait_healthy NAME TIMEOUT
  local name=$1 t=$2 deadline=$(( $(date +%s) + t )) s
  while (( $(date +%s) < deadline )); do
    s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null) || return 1
    case "$s" in healthy|running) return 0 ;; starting|created|restarting) ;; *) return 1 ;; esac
    sleep 3
  done
  return 1
}

ps_args=(--format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "com.docker.compose.project.config_files"}}')
(( INCLUDE_STOPPED )) && ps_args=(-a "${ps_args[@]}")

mapfile -t rows < <(docker ps "${ps_args[@]}")
(( ${#rows[@]} )) || { log "no containers found"; exit 0; }

declare -A COMPOSE_DIR COMPOSE_FILES
declare -a COMPOSE_PROJECTS STANDALONE

for row in "${rows[@]}"; do
  IFS=$'\t' read -r cid name image project workdir cfgfiles <<<"$row"
  if [[ -n $project ]]; then
    in_filter "$project" || in_filter "$name" || continue
    if [[ -z ${COMPOSE_DIR[$project]:-} ]]; then
      COMPOSE_PROJECTS+=("$project")
      COMPOSE_DIR[$project]=$workdir
      COMPOSE_FILES[$project]=$cfgfiles
    fi
  else
    in_filter "$name" || continue
    STANDALONE+=("$cid"$'\t'"$name"$'\t'"$image")
  fi
done

failures=0; rollbacks_ok=0; rollback_failed=0; updated_ok=0

# ---- compose projects ----
for project in "${COMPOSE_PROJECTS[@]}"; do
  dir=${COMPOSE_DIR[$project]}
  files=${COMPOSE_FILES[$project]}
  log "compose project: $project ($dir)"
  if [[ ! -d $dir ]]; then warn "  working dir missing, skipping"; continue; fi
  file_args=""
  IFS=',' read -ra fs <<<"$files"
  for f in "${fs[@]}"; do [[ -n $f ]] && file_args+=" -f $(printf '%q' "$f")"; done

  # snapshot pre-image digests for each service
  before=$(cd "$dir" && docker compose -p "$project" $file_args ps --format json 2>/dev/null \
            | jq -s '[.[] | {name:.Name, image:.Image, id: (.Image // "" )}]' || echo '[]')
  state_append "$(jq -nc --arg p "$project" --arg d "$dir" --argjson b "$before" \
                  '{kind:"compose",project:$p,dir:$d,before:$b}')"

  if ! run "cd $(printf '%q' "$dir") && docker compose -p $(printf '%q' "$project")$file_args pull"; then
    err "  pull failed for $project"; failures=$((failures+1)); continue
  fi
  if ! run "cd $(printf '%q' "$dir") && docker compose -p $(printf '%q' "$project")$file_args up -d --remove-orphans"; then
    err "  up failed for $project"; failures=$((failures+1)); continue
  fi

  # health check each service
  unhealthy=()
  while read -r svc; do
    [[ -z $svc ]] && continue
    wait_healthy "$svc" "$HEALTH_TIMEOUT" || unhealthy+=("$svc")
  done < <(cd "$dir" && docker compose -p "$project" $file_args ps --format '{{.Name}}' 2>/dev/null)

  if (( ${#unhealthy[@]} )); then
    err "  unhealthy after update: ${unhealthy[*]}"
    failures=$((failures+1))
    if (( ROLLBACK )); then
      warn "  rolling back compose project $project"
      if run "cd $(printf '%q' "$dir") && docker compose -p $(printf '%q' "$project")$file_args down"; then
        # bring previous-image services back; relies on local image cache
        if run "cd $(printf '%q' "$dir") && docker compose -p $(printf '%q' "$project")$file_args up -d"; then
          rollbacks_ok=$((rollbacks_ok+1))
        else rollback_failed=$((rollback_failed+1)); fi
      else rollback_failed=$((rollback_failed+1)); fi
    fi
  else
    updated_ok=$((updated_ok+1))
  fi
done

# ---- standalone containers ----
for entry in "${STANDALONE[@]}"; do
  IFS=$'\t' read -r cid name image <<<"$entry"
  log "standalone: $name ($image)"

  digest_before=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")
  runlike_cmd=""
  if command -v runlike >/dev/null 2>&1; then
    runlike_cmd=$(runlike "$cid" 2>/dev/null || true)
  fi
  state_append "$(jq -nc --arg n "$name" --arg i "$image" --arg d "$digest_before" --arg r "$runlike_cmd" \
                  '{kind:"standalone",name:$n,image:$i,digest_before:$d,runlike:$r}')"

  if ! run "docker pull $(printf '%q' "$image")"; then
    err "  pull failed for $name"; failures=$((failures+1)); continue
  fi
  digest_after=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")
  if [[ -n $digest_before && $digest_before == "$digest_after" ]]; then
    log "  already up to date"; updated_ok=$((updated_ok+1)); continue
  fi

  if [[ -z $runlike_cmd ]]; then
    err "  cannot recreate $name without 'runlike' (pip install runlike)"
    failures=$((failures+1)); continue
  fi

  log "  recreating $name"
  run "docker rm -f $(printf '%q' "$name")" || true
  if ! run "$runlike_cmd"; then
    err "  recreate failed for $name"; failures=$((failures+1))
    if (( ROLLBACK )) && [[ -n $digest_before ]]; then
      warn "  rolling back $name to $digest_before"
      run "docker tag $(printf '%q' "$digest_before") $(printf '%q' "$image")" \
        && run "$runlike_cmd" \
        && rollbacks_ok=$((rollbacks_ok+1)) \
        || rollback_failed=$((rollback_failed+1))
    fi
    continue
  fi

  if ! wait_healthy "$name" "$HEALTH_TIMEOUT"; then
    err "  $name unhealthy after update"; failures=$((failures+1))
    if (( ROLLBACK )) && [[ -n $digest_before ]]; then
      warn "  rolling back $name to $digest_before"
      run "docker rm -f $(printf '%q' "$name")" || true
      run "docker tag $(printf '%q' "$digest_before") $(printf '%q' "$image")" \
        && run "$runlike_cmd" \
        && rollbacks_ok=$((rollbacks_ok+1)) \
        || rollback_failed=$((rollback_failed+1))
    fi
  else
    updated_ok=$((updated_ok+1))
  fi
done

(( PRUNE )) && run "docker image prune -f"

# ---- finalize ----
exit_code=0
if (( failures > 0 )); then
  if (( rollback_failed > 0 )); then exit_code=2; else exit_code=1; fi
  if [[ -n $NOTIFY && -x $NOTIFY_TOOL ]]; then
    subj="[Fred] container-update FAILED on $(hostname)"
    (( exit_code == 2 )) && subj="[Fred] container-update FAILED + rollback failed on $(hostname)"
    { echo "Log: $LOG"; echo "State: $STATE_FILE"; echo
      echo "Updated OK: $updated_ok  Failures: $failures  Rollbacks OK: $rollbacks_ok  Rollback failed: $rollback_failed"
      echo; echo "--- last 200 log lines ---"; tail -n 200 "$LOG" 2>/dev/null
    } | "$NOTIFY_TOOL" "$NOTIFY" "$subj" - || warn "notify-email failed"
  fi
fi

# Final JSON line for the orchestrator (last stdout line).
jq -nc --argjson ok "$updated_ok" --argjson f "$failures" \
       --argjson rok "$rollbacks_ok" --argjson rf "$rollback_failed" \
       --arg log "$LOG" --arg state "$STATE_FILE" \
       '{target:"truenas-docker",status:(if $f==0 then "ok" elif $rf==0 then "rolled_back" else "restore_failed" end),
         needs_reboot:false,updated:$ok,failures:$f,rollbacks_ok:$rok,rollback_failed:$rf,
         log:$log,state:$state}'

exit $exit_code
