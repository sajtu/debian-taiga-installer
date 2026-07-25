#!/usr/bin/env bash
#
# Interactive uninstaller for deployments created by debian-setup-taiga.bash.
# Removes the Taiga Compose stack, its persistent volumes, systemd unit,
# installation directory, and (optionally) the local service account and logs.
#
# Docker Engine, cached container images, Caddy, TLS certificates, and unrelated
# Docker projects are intentionally preserved.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_INSTALL_DIR="/opt/taiga"
readonly DEFAULT_SERVICE_USER="taiga-svc"
readonly SYSTEMD_UNIT="taiga-compose.service"
readonly UNIT_FILE="/etc/systemd/system/${SYSTEMD_UNIT}"
readonly INSTALLER_LOG="/var/log/taiga-installer.log"
readonly UNINSTALLER_LOG="/var/log/taiga-uninstaller.log"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
SERVICE_USER="$DEFAULT_SERVICE_USER"
REMOVE_SERVICE_USER=0
REMOVE_INSTALLER_LOG=0
COMPOSE_FILE=""

declare -a COMPOSE_PROJECTS=()
declare -A SEEN_PROJECTS=()

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME}

Interactively remove a Taiga deployment created by debian-setup-taiga.bash.

The uninstaller permanently removes:
  - Taiga containers
  - Taiga Docker volumes, including PostgreSQL data and uploaded files
  - Taiga Docker networks
  - ${SYSTEMD_UNIT}
  - the selected Taiga installation directory

It can optionally remove the local service account and installer log.
Docker Engine, Docker images, Caddy, and TLS certificates are preserved.
EOF
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local message="$*"
  printf '[%s] %s\n' "$(timestamp)" "$message"
  if [[ -e "$UNINSTALLER_LOG" && -w "$UNINSTALLER_LOG" ]]; then
    printf '[%s] %s\n' "$(timestamp)" "$message" >>"$UNINSTALLER_LOG"
  fi
}

warn() {
  log "WARNING: $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

on_error() {
  local exit_code=$?
  local line_number=$1
  log "ERROR: Uninstallation stopped at line ${line_number} (exit ${exit_code})."
  log "Review ${UNINSTALLER_LOG} and the command output above."
  exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

confirm() {
  local prompt="$1"
  local default_answer="${2:-no}"
  local reply

  if [[ "$default_answer" == "yes" ]]; then
    read -r -p "${prompt} [Y/n]: " reply
    reply="${reply:-y}"
  else
    read -r -p "${prompt} [y/N]: " reply
    reply="${reply:-n}"
  fi

  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

require_root_and_tty() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  [[ $# -eq 0 ]] || die "Unknown argument: $1"
  [[ $EUID -eq 0 ]] ||
    die "Run this uninstaller with sudo: sudo ./${SCRIPT_NAME}"
  [[ -t 0 && -t 1 ]] ||
    die "This uninstaller requires an interactive terminal."

  touch "$UNINSTALLER_LOG"
  chmod 0600 "$UNINSTALLER_LOG"
}

validate_install_path() {
  local candidate="$1"

  [[ "$candidate" == /* ]] ||
    die "The installation path must be absolute."
  [[ "$candidate" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "The installation path contains unsupported characters."

  case "$candidate" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "Refusing unsafe installation path: ${candidate}"
      ;;
  esac

  [[ ! -L "$candidate" ]] ||
    die "Refusing to use a symbolic link as the installation path: ${candidate}"
}

discover_settings() {
  local detected_dir=""
  local detected_user=""
  local reply=""

  if [[ -e "$UNIT_FILE" ]]; then
    detected_dir="$(
      systemctl show "$SYSTEMD_UNIT" \
        --property=WorkingDirectory \
        --value 2>/dev/null || true
    )"
    detected_user="$(
      systemctl show "$SYSTEMD_UNIT" \
        --property=User \
        --value 2>/dev/null || true
    )"
  fi

  [[ -n "$detected_dir" ]] && INSTALL_DIR="$detected_dir"
  [[ -n "$detected_user" ]] && SERVICE_USER="$detected_user"

  read -r -p "Taiga installation directory [${INSTALL_DIR}]: " reply
  INSTALL_DIR="${reply:-$INSTALL_DIR}"
  INSTALL_DIR="${INSTALL_DIR%/}"
  validate_install_path "$INSTALL_DIR"

  reply=""
  read -r -p "Taiga service account [${SERVICE_USER}]: " reply
  SERVICE_USER="${reply:-$SERVICE_USER}"
  [[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] ||
    die "Invalid service account name: ${SERVICE_USER}"

  if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  fi
}

show_intro() {
  cat <<EOF

Taiga Docker uninstallation
===========================

Selected installation directory : ${INSTALL_DIR}
Selected service account        : ${SERVICE_USER}
Systemd unit                    : ${SYSTEMD_UNIT}

This will permanently delete the Taiga containers and Docker volumes,
including the PostgreSQL database, users, projects, attachments, and uploads.

This will NOT remove:

  - Docker Engine or Docker Compose
  - cached Docker images
  - Caddy or /etc/caddy/Caddyfile
  - certificates under /etc/ssl
  - acme.sh or its certificate store
  - unrelated Docker projects
EOF

  confirm "Continue and permanently remove this Taiga deployment?" "no" ||
    die "Cancelled by user."

  REMOVE_SERVICE_USER=0
  if local_user_exists "$SERVICE_USER"; then
    if confirm "Remove the local service account ${SERVICE_USER} and its home?" "yes"; then
      REMOVE_SERVICE_USER=1
    fi
  fi

  REMOVE_INSTALLER_LOG=0
  if [[ -e "$INSTALLER_LOG" ]] &&
    confirm "Remove the installer log ${INSTALLER_LOG}?" "yes"; then
    REMOVE_INSTALLER_LOG=1
  fi
}

local_user_exists() {
  local username="$1"
  awk -F: -v wanted="$username" '$1 == wanted { found=1 } END { exit !found }' \
    /etc/passwd
}

add_project() {
  local project="$1"
  [[ -n "$project" ]] || return
  [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
    die "Docker returned an unsafe Compose project name: ${project}"

  if [[ -z "${SEEN_PROJECTS[$project]+present}" ]]; then
    COMPOSE_PROJECTS+=("$project")
    SEEN_PROJECTS["$project"]=1
  fi
}

discover_compose_projects() {
  local container_id
  local project
  local default_project

  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    project="$(
      docker inspect \
        --format '{{ index .Config.Labels "com.docker.compose.project" }}' \
        "$container_id" 2>/dev/null || true
    )"
    add_project "$project"
  done < <(
    docker ps -aq \
      --filter "label=com.docker.compose.project.working_dir=${INSTALL_DIR}"
  )

  default_project="${INSTALL_DIR##*/}"
  if docker ps -aq \
      --filter "label=com.docker.compose.project=${default_project}" |
      grep -q . ||
    docker volume ls -q \
      --filter "label=com.docker.compose.project=${default_project}" |
      grep -q . ||
    docker network ls -q \
      --filter "label=com.docker.compose.project=${default_project}" |
      grep -q .; then
    add_project "$default_project"
  fi
}

show_docker_targets() {
  local project

  if (( ${#COMPOSE_PROJECTS[@]} == 0 )); then
    log "No Docker Compose resources were found for ${INSTALL_DIR}."
    return
  fi

  for project in "${COMPOSE_PROJECTS[@]}"; do
    printf '\nDocker resources for Compose project %s:\n\n' "$project"

    docker ps -a \
      --filter "label=com.docker.compose.project=${project}" \
      --format '  container  {{.Names}}  [{{.Status}}]' || true

    while IFS= read -r item; do
      [[ -n "$item" ]] && printf '  volume     %s\n' "$item"
    done < <(
      docker volume ls -q \
        --filter "label=com.docker.compose.project=${project}"
    )

    while IFS= read -r item; do
      [[ -n "$item" ]] && printf '  network    %s\n' "$item"
    done < <(
      docker network ls \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Name}}'
    )
  done

  printf '\n'
  confirm "Remove exactly the Docker resources shown above?" "no" ||
    die "Cancelled before removing Docker resources."
}

stop_service() {
  if systemctl cat "$SYSTEMD_UNIT" >/dev/null 2>&1; then
    log "Stopping and disabling ${SYSTEMD_UNIT}."
    systemctl stop "$SYSTEMD_UNIT" 2>/dev/null || true
    systemctl disable "$SYSTEMD_UNIT" 2>/dev/null || true
  else
    log "${SYSTEMD_UNIT} is not installed."
  fi
}

compose_down_if_possible() {
  if [[ -z "$COMPOSE_FILE" ]]; then
    warn "Compose file is unavailable; continuing with Docker label cleanup."
    return
  fi

  log "Taking down the Compose stack using ${COMPOSE_FILE}."
  if ! docker compose \
      --project-directory "$INSTALL_DIR" \
      --file "$COMPOSE_FILE" \
      down --volumes --remove-orphans; then
    warn "Compose cleanup was incomplete; continuing with Docker label cleanup."
  fi
}

remove_docker_resources() {
  local project
  local -a resource_ids=()

  for project in "${COMPOSE_PROJECTS[@]}"; do
    mapfile -t resource_ids < <(
      docker ps -aq \
        --filter "label=com.docker.compose.project=${project}"
    )
    if (( ${#resource_ids[@]} > 0 )); then
      log "Removing containers for Compose project ${project}."
      docker rm -f "${resource_ids[@]}"
    fi

    mapfile -t resource_ids < <(
      docker volume ls -q \
        --filter "label=com.docker.compose.project=${project}"
    )
    if (( ${#resource_ids[@]} > 0 )); then
      log "Removing persistent volumes for Compose project ${project}."
      docker volume rm "${resource_ids[@]}"
    fi

    mapfile -t resource_ids < <(
      docker network ls -q \
        --filter "label=com.docker.compose.project=${project}"
    )
    if (( ${#resource_ids[@]} > 0 )); then
      log "Removing networks for Compose project ${project}."
      docker network rm "${resource_ids[@]}"
    fi
  done
}

remove_systemd_unit() {
  if [[ -e "$UNIT_FILE" ]]; then
    log "Removing ${UNIT_FILE}."
    rm -f -- "$UNIT_FILE"
  fi

  systemctl daemon-reload
  systemctl reset-failed "$SYSTEMD_UNIT" 2>/dev/null || true
}

directory_is_recognized_or_empty() {
  local directory="$1"

  [[ -d "$directory" ]] || return 1
  [[ -z "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]] &&
    return 0
  [[ -f "${directory}/docker-compose.yml" ]] && return 0
  [[ -f "${directory}/taiga-manage.sh" ]] && return 0
  [[ -f "${directory}/.env" ]] &&
    grep -qE '^(TAIGA_DOMAIN|TAIGA_SCHEME)=' "${directory}/.env" &&
    return 0
  return 1
}

remove_install_directory() {
  if [[ ! -e "$INSTALL_DIR" ]]; then
    log "${INSTALL_DIR} is already absent."
    return
  fi

  if directory_is_recognized_or_empty "$INSTALL_DIR"; then
    log "Removing Taiga installation directory ${INSTALL_DIR}."
    rm -rf -- "$INSTALL_DIR"
    return
  fi

  warn "${INSTALL_DIR} exists but no longer looks like a recognizable Taiga installation."
  warn "Its contents will be preserved unless you explicitly approve their removal."
  if confirm "Remove the unrecognized directory ${INSTALL_DIR} anyway?" "no"; then
    rm -rf -- "$INSTALL_DIR"
  else
    warn "Preserved ${INSTALL_DIR}."
  fi
}

remove_optional_files_and_account() {
  if (( REMOVE_SERVICE_USER == 1 )) && local_user_exists "$SERVICE_USER"; then
    log "Removing local service account ${SERVICE_USER} and its home."
    userdel --remove "$SERVICE_USER" 2>/dev/null ||
      warn "The account was removed with warnings or requires manual review."
  fi

  if (( REMOVE_INSTALLER_LOG == 1 )); then
    log "Removing ${INSTALLER_LOG}."
    rm -f -- "$INSTALLER_LOG"
  fi
}

verify_cleanup() {
  local project
  local leftovers=0

  for project in "${COMPOSE_PROJECTS[@]}"; do
    if docker ps -aq \
        --filter "label=com.docker.compose.project=${project}" |
        grep -q .; then
      warn "Containers remain for Compose project ${project}."
      leftovers=1
    fi
    if docker volume ls -q \
        --filter "label=com.docker.compose.project=${project}" |
        grep -q .; then
      warn "Volumes remain for Compose project ${project}."
      leftovers=1
    fi
    if docker network ls -q \
        --filter "label=com.docker.compose.project=${project}" |
        grep -q .; then
      warn "Networks remain for Compose project ${project}."
      leftovers=1
    fi
  done

  if (( leftovers == 1 )); then
    die "Taiga cleanup is incomplete; review the warnings above."
  fi
}

show_completion() {
  cat <<EOF

Taiga uninstallation completed
==============================

Removed:

  - Taiga containers and Compose networks
  - Taiga persistent Docker volumes
  - ${SYSTEMD_UNIT}
  - ${INSTALL_DIR}, unless preservation was requested

Preserved:

  - Docker Engine and Docker Compose
  - cached container images
  - Caddy and its configuration
  - TLS certificates and acme.sh data
  - unrelated Docker projects

Caddy may return 502 Bad Gateway until Taiga is installed again or its site
configuration is removed. Uninstaller log: ${UNINSTALLER_LOG}
EOF
}

main() {
  require_root_and_tty "$@"
  command -v docker >/dev/null 2>&1 ||
    die "Docker is not installed; Docker resource cleanup cannot continue."

  discover_settings
  show_intro
  stop_service
  discover_compose_projects
  show_docker_targets
  compose_down_if_possible
  remove_docker_resources
  remove_systemd_unit
  remove_install_directory
  remove_optional_files_and_account
  verify_cleanup
  show_completion
}

main "$@"
