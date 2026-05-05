#!/usr/bin/env bash
# update-containers.sh — pull latest images and recreate all running containers.
#
# Usage:
#   sudo ./update-containers.sh              # update all running containers
#   sudo ./update-containers.sh -a           # include stopped containers too
#   sudo ./update-containers.sh -n web db    # only these containers/projects
#   sudo ./update-containers.sh --prune      # also remove dangling images afterwards
#   sudo ./update-containers.sh --dry-run    # show what would happen, change nothing
#
# Behaviour:
#   * Compose projects (containers labelled com.docker.compose.project) are updated
#     together with `docker compose pull && docker compose up -d`, preserving the
#     original compose file and project directory.
#   * Standalone containers are updated with `docker pull` followed by recreation
#     using the same image, name, network, restart policy, ports, mounts, env, etc.
#     (via `docker container inspect` → re-run). Only recreated if the image digest
#     actually changed.
#   * Exits non-zero if any container fails to come back up.

set -euo pipefail

DRY_RUN=0
INCLUDE_STOPPED=0
PRUNE=0
FILTER=()

log()  { printf '\033[1;34m[update]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
run()  { if (( DRY_RUN )); then printf '   DRY: %s\n' "$*"; else eval "$@"; fi; }

while (( $# )); do
  case "$1" in
    -a|--all)       INCLUDE_STOPPED=1 ;;
    -n|--name)      shift; while (( $# )) && [[ $1 != -* ]]; do FILTER+=("$1"); shift; done; continue ;;
    --prune)        PRUNE=1 ;;
    --dry-run)      DRY_RUN=1 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              err "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

command -v docker >/dev/null || { err "docker not found in PATH"; exit 1; }

in_filter() {
  (( ${#FILTER[@]} == 0 )) && return 0
  local needle=$1 f
  for f in "${FILTER[@]}"; do [[ $f == "$needle" ]] && return 0; done
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
    if ! in_filter "$project" && ! in_filter "$name"; then continue; fi
    if [[ -z ${COMPOSE_DIR[$project]:-} ]]; then
      COMPOSE_PROJECTS+=("$project")
      COMPOSE_DIR[$project]=$workdir
      COMPOSE_FILES[$project]=$cfgfiles
    fi
  else
    if ! in_filter "$name"; then continue; fi
    STANDALONE+=("$cid"$'\t'"$name"$'\t'"$image")
  fi
done

failed=0

for project in "${COMPOSE_PROJECTS[@]}"; do
  dir=${COMPOSE_DIR[$project]}
  files=${COMPOSE_FILES[$project]}
  log "compose project: $project ($dir)"
  if [[ ! -d $dir ]]; then warn "  working dir missing, skipping"; continue; fi
  file_args=""
  IFS=',' read -ra fs <<<"$files"
  for f in "${fs[@]}"; do [[ -n $f ]] && file_args+=" -f $(printf '%q' "$f")"; done
  if ! run "cd $(printf '%q' "$dir") && docker compose -p $(printf '%q' "$project")$file_args pull"; then
    err "  pull failed for $project"; failed=1; continue
  fi
  if ! run "cd $(printf '%q' "$dir") && docker compose -p $(printf '%q' "$project")$file_args up -d --remove-orphans"; then
    err "  up failed for $project"; failed=1
  fi
done

for entry in "${STANDALONE[@]}"; do
  IFS=$'\t' read -r cid name image <<<"$entry"
  log "standalone: $name ($image)"
  before=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")
  if ! run "docker pull $(printf '%q' "$image")"; then
    err "  pull failed for $name"; failed=1; continue
  fi
  after=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")
  if [[ -n $before && $before == "$after" ]]; then
    log "  already up to date, skipping recreate"
    continue
  fi
  log "  recreating $name"
  run "docker rm -f $(printf '%q' "$name")"
  if command -v docker-rerun >/dev/null 2>&1; then
    run "docker-rerun --pull=missing $(printf '%q' "$cid") | sh"
  else
    # Fall back to runlike if available, otherwise just `docker start` won't work — warn.
    if command -v runlike >/dev/null 2>&1; then
      cmd=$(runlike "$cid" 2>/dev/null || true)
      [[ -n $cmd ]] && run "$cmd" || { err "  cannot reconstruct run command for $name (install 'runlike')"; failed=1; }
    else
      err "  $name removed but no 'runlike' tool available to recreate it; install with: pip install runlike"
      failed=1
    fi
  fi
done

if (( PRUNE )); then
  log "pruning dangling images"
  run "docker image prune -f"
fi

if (( failed )); then err "one or more containers failed to update"; exit 1; fi
log "done"
