#!/usr/bin/env bash
#
# Interactive Taiga installer for Debian 11/12/13.
# Installs Docker Engine from Docker's official APT repository when needed,
# deploys Taiga's stable Docker Compose configuration, and creates a systemd
# unit that starts the stack after Docker.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_INSTALL_DIR="/opt/taiga"
readonly DEFAULT_SERVICE_USER="taiga-svc"
readonly DEFAULT_SERVICE_HOME="/var/lib/taiga"
readonly TAIGA_REPOSITORY="https://github.com/taigaio/taiga-docker.git"
readonly TAIGA_BRANCH="stable"
readonly SYSTEMD_UNIT="taiga-compose.service"
readonly LOG_FILE="/var/log/taiga-installer.log"

APT_UPDATED=0
NEW_INSTALL=0
INSTALL_DIR=""
SERVICE_USER=""
SERVICE_GROUP=""
SERVICE_HOME=""
PUBLIC_URL=""
TAIGA_SCHEME=""
TAIGA_DOMAIN=""
TAIGA_SUBPATH=""
WEBSOCKETS_SCHEME=""

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME}

Interactive installer for a production-style, single-VM Taiga deployment.
Supported operating systems: Debian 11, 12, and 13.

The script will explain its actions and request confirmation before changing
the system. It does not support unattended operation.
EOF
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local message="$*"
  printf '[%s] %s\n' "$(timestamp)" "$message"
  if [[ -e "$LOG_FILE" && -w "$LOG_FILE" ]]; then
    printf '[%s] %s\n' "$(timestamp)" "$message" >>"$LOG_FILE"
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
  log "ERROR: Installation stopped at line ${line_number} (exit ${exit_code})."
  log "Review ${LOG_FILE} and the command output above."
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

  [[ $EUID -eq 0 ]] || die "Run this installer with sudo: sudo ./${SCRIPT_NAME}"
  [[ -t 0 && -t 1 ]] || die "This installer requires an interactive terminal."

  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

load_and_validate_os() {
  [[ -r /etc/os-release ]] || die "Cannot identify this operating system."
  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "debian" ]] || die "This installer supports Debian only."

  case "${VERSION_CODENAME:-}" in
    bullseye|bookworm|trixie)
      ;;
    *)
      die "Unsupported Debian release: ${VERSION_CODENAME:-unknown}. Supported: bullseye, bookworm, trixie."
      ;;
  esac

  log "Detected Debian ${VERSION_ID:-unknown} (${VERSION_CODENAME})."
}

show_intro() {
  cat <<'EOF'

Taiga Docker installation
=========================

Before making changes, this installer will:

  1. Check Debian, required utilities, Docker Engine, and Docker Compose.
  2. Install missing packages from Debian and Docker's official repository.
  3. Create a locked service account with a usable shell for:
       sudo su - taiga-svc
  4. add that account to the root-equivalent local "docker" group;
  5. clone Taiga's stable Docker deployment into /opt/taiga by default;
  6. generate cryptographically random database and application secrets;
  7. add container restart policies;
  8. install and enable a systemd unit for automatic startup;
  9. optionally create the initial Taiga administrator.

Docker group membership grants effective root access to this host. The Taiga
service account will have a locked password, so direct password login is
disabled even though administrators can enter it through sudo.

The installer will never overwrite an unrelated non-empty installation path.
EOF

  confirm "Proceed with these changes?" "no" || die "Cancelled by user."
}

apt_update_once() {
  if (( APT_UPDATED == 0 )); then
    log "Refreshing APT package metadata."
    apt-get update
    APT_UPDATED=1
  fi
}

ensure_debian_packages() {
  local required_packages=(
    ca-certificates
    curl
    git
    openssl
    passwd
    sudo
    util-linux
  )
  local missing_packages=()
  local package

  for package in "${required_packages[@]}"; do
    if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
      missing_packages+=("$package")
    fi
  done

  if (( ${#missing_packages[@]} == 0 )); then
    log "Required Debian utilities are already installed."
    return
  fi

  log "Installing missing Debian packages: ${missing_packages[*]}"
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
}

docker_repo_is_configured() {
  [[ -r /etc/apt/sources.list.d/docker.sources ]] &&
    grep -q 'download.docker.com/linux/debian' /etc/apt/sources.list.d/docker.sources
}

configure_docker_repository() {
  local architecture
  architecture="$(dpkg --print-architecture)"

  log "Configuring Docker's official Debian APT repository."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  APT_UPDATED=0
  apt_update_once
}

installed_conflicting_docker_packages() {
  local package
  local conflicts=()

  for package in docker.io docker-compose podman-docker containerd runc; do
    if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
      conflicts+=("$package")
    fi
  done

  if (( ${#conflicts[@]} > 0 )); then
    printf '%s\n' "${conflicts[@]}"
  fi
}

install_official_docker() {
  local conflicts_text
  local conflicts=()

  mapfile -t conflicts < <(installed_conflicting_docker_packages)
  if (( ${#conflicts[@]} > 0 )); then
    conflicts_text="${conflicts[*]}"
    warn "Conflicting container packages are installed: ${conflicts_text}"
    warn "Migrating to Docker CE requires removing those packages. Existing /var/lib/docker data is not intentionally deleted."
    confirm "Remove the conflicting packages and install Docker CE?" "no" ||
      die "Docker installation cannot continue while conflicting packages remain."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${conflicts[@]}"
  fi

  docker_repo_is_configured || configure_docker_repository
  apt_update_once

  log "Installing Docker Engine and the Docker Compose plugin."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
}

ensure_docker() {
  local need_docker=0

  command -v docker >/dev/null 2>&1 || need_docker=1
  if (( need_docker == 0 )) && ! docker compose version >/dev/null 2>&1; then
    warn "Docker is present, but the Docker Compose plugin is missing."
    need_docker=1
  fi

  if (( need_docker == 1 )); then
    install_official_docker
  else
    log "Docker Engine and Docker Compose are already installed."
  fi

  systemctl enable --now docker.service
  systemctl enable containerd.service
  docker info >/dev/null
  docker compose version >/dev/null
  log "Docker is enabled and responding."
}

prompt_service_user() {
  local reply

  read -r -p "Service account [${DEFAULT_SERVICE_USER}]: " reply
  SERVICE_USER="${reply:-$DEFAULT_SERVICE_USER}"

  [[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] ||
    die "Invalid service account name: ${SERVICE_USER}"

  if [[ "$SERVICE_USER" == "$DEFAULT_SERVICE_USER" ]]; then
    SERVICE_HOME="$DEFAULT_SERVICE_HOME"
  else
    SERVICE_HOME="/var/lib/${SERVICE_USER}"
  fi
}

ensure_service_user() {
  local passwd_entry

  if grep -qE "^${SERVICE_USER}:" /etc/passwd; then
    passwd_entry="$(getent passwd "$SERVICE_USER")"
    log "Reusing existing local service account ${SERVICE_USER}: ${passwd_entry}"
    SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
  elif getent passwd "$SERVICE_USER" >/dev/null; then
    die "${SERVICE_USER} resolves through an external identity provider. Choose a different local service account name."
  else
    log "Creating locked local service account ${SERVICE_USER}."
    useradd \
      --system \
      --user-group \
      --home-dir "$SERVICE_HOME" \
      --create-home \
      --shell /bin/bash \
      "$SERVICE_USER"
  fi

  SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
  install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$SERVICE_HOME"
  usermod -aG docker "$SERVICE_USER"
  passwd -l "$SERVICE_USER" >/dev/null 2>&1 || true

  if [[ "$(getent passwd "$SERVICE_USER" | cut -d: -f7)" != "/bin/bash" ]]; then
    log "Setting ${SERVICE_USER}'s shell to /bin/bash for administrative sudo sessions."
    usermod --shell /bin/bash "$SERVICE_USER"
  fi

  id "$SERVICE_USER" | grep -qE 'groups=.*\bdocker\b' ||
    die "Failed to add ${SERVICE_USER} to the docker group."

  run_as_service docker info >/dev/null
  log "Service account ${SERVICE_USER} can access Docker."
}

run_as_service() {
  runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" "$@"
}

run_compose() {
  (
    cd "$INSTALL_DIR"
    run_as_service docker compose "$@"
  )
}

validate_install_path() {
  local candidate="$1"

  [[ "$candidate" == /* ]] || die "The installation path must be absolute."
  [[ "$candidate" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "The installation path may contain only letters, numbers, slash, dot, underscore, and hyphen."

  case "$candidate" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "Refusing unsafe installation path: ${candidate}"
      ;;
  esac
}

prompt_install_path() {
  local reply
  local custom_path

  if confirm "Install Taiga in the default location ${DEFAULT_INSTALL_DIR}?" "yes"; then
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
  else
    read -r -p "Enter an absolute installation path: " custom_path
    [[ -n "$custom_path" ]] || die "No installation path supplied."
    INSTALL_DIR="${custom_path%/}"
  fi

  validate_install_path "$INSTALL_DIR"

  if [[ -e "$INSTALL_DIR" ]]; then
    if [[ -d "$INSTALL_DIR/.git" ]] &&
      git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null | grep -qx "$TAIGA_REPOSITORY"; then
      log "Recognized an existing Taiga repository at ${INSTALL_DIR}; preserving its configuration."
      NEW_INSTALL=0
      chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
      run_as_service test -x "$INSTALL_DIR" ||
        die "${SERVICE_USER} cannot traverse the parent directories of ${INSTALL_DIR}."
      return
    fi

    if [[ -d "$INSTALL_DIR" ]] && [[ -z "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      log "Using existing empty directory ${INSTALL_DIR}."
    else
      die "${INSTALL_DIR} exists and is not a recognized Taiga installation or empty directory."
    fi
  else
    log "Creating installation directory ${INSTALL_DIR}."
    mkdir -p "$INSTALL_DIR"
  fi

  chown "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
  chmod 0750 "$INSTALL_DIR"
  run_as_service test -x "$INSTALL_DIR" ||
    die "${SERVICE_USER} cannot traverse the parent directories of ${INSTALL_DIR}."
  NEW_INSTALL=1
}

check_install_capacity() {
  local available_kb
  local available_gb

  available_kb="$(df -Pk "$INSTALL_DIR" | awk 'NR == 2 { print $4 }')"
  [[ "$available_kb" =~ ^[0-9]+$ ]] || die "Could not determine free space for ${INSTALL_DIR}."
  available_gb=$((available_kb / 1024 / 1024))

  log "Filesystem containing ${INSTALL_DIR} has approximately ${available_gb} GiB free."
  if (( available_gb < 5 )); then
    die "At least 5 GiB free is required to continue safely."
  elif (( available_gb < 20 )); then
    warn "Taiga's documentation recommends at least 20 GiB free."
    confirm "Continue with approximately ${available_gb} GiB free?" "no" ||
      die "Cancelled because available storage is below the recommendation."
  fi
}

clone_taiga() {
  if (( NEW_INSTALL == 0 )); then
    return
  fi

  log "Cloning Taiga branch '${TAIGA_BRANCH}' into ${INSTALL_DIR}."
  run_as_service git clone \
    --branch "$TAIGA_BRANCH" \
    --single-branch \
    "$TAIGA_REPOSITORY" \
    "$INSTALL_DIR"
}

parse_public_url() {
  local value="$1"
  local path=""

  if [[ "$value" =~ ^(https?)://([^/?#]+)(/[^?#]*)?$ ]]; then
    TAIGA_SCHEME="${BASH_REMATCH[1]}"
    TAIGA_DOMAIN="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[3]:-}"
  else
    return 1
  fi

  [[ "$TAIGA_DOMAIN" =~ ^[][A-Za-z0-9._:-]+$ ]] || return 1

  if [[ "$path" == "/" ]]; then
    path=""
  elif [[ -n "$path" ]]; then
    [[ "$path" =~ ^(/[A-Za-z0-9._~-]+)+/?$ ]] || return 1
    path="${path%/}"
  fi

  TAIGA_SUBPATH="$path"
  if [[ "$TAIGA_SCHEME" == "https" ]]; then
    WEBSOCKETS_SCHEME="wss"
  else
    WEBSOCKETS_SCHEME="ws"
  fi
}

prompt_public_url() {
  local detected_ip
  local default_url
  local reply

  detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  default_url="http://${detected_ip:-127.0.0.1}:9000"

  while true; do
    read -r -p "Browser-facing Taiga URL [${default_url}]: " reply
    PUBLIC_URL="${reply:-$default_url}"
    if parse_public_url "$PUBLIC_URL"; then
      break
    fi
    printf 'Enter a URL such as http://192.168.1.50:9000 or https://taiga.example.com\n'
  done

  log "Taiga will be configured for ${PUBLIC_URL}."
  if [[ "$TAIGA_SCHEME" == "http" ]]; then
    warn "HTTP is suitable for initial LAN testing. Use HTTPS through a reverse proxy for normal authenticated use."
  fi
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local temporary

  temporary="$(mktemp)"
  awk -v wanted_key="$key" -v replacement="$value" '
    BEGIN { found = 0 }
    index($0, wanted_key "=") == 1 {
      print wanted_key "=" replacement
      found = 1
      next
    }
    { print }
    END {
      if (!found) {
        print wanted_key "=" replacement
      }
    }
  ' "$file" >"$temporary"
  cat "$temporary" >"$file"
  rm -f "$temporary"
}

configure_taiga_env() {
  local env_file="${INSTALL_DIR}/.env"
  local secret_key
  local postgres_password
  local rabbitmq_password
  local erlang_cookie

  if (( NEW_INSTALL == 0 )) && [[ -s "$env_file" ]]; then
    log "Preserving the existing ${env_file}; no secrets were rotated."
    chown "$SERVICE_USER:$SERVICE_GROUP" "$env_file"
    chmod 0600 "$env_file"
    return
  fi

  [[ -f "$env_file" ]] || die "Taiga's .env template is missing from ${INSTALL_DIR}."
  prompt_public_url

  secret_key="$(openssl rand -hex 48)"
  postgres_password="$(openssl rand -hex 32)"
  rabbitmq_password="$(openssl rand -hex 32)"
  erlang_cookie="$(openssl rand -hex 32)"

  log "Writing URL settings and newly generated secrets to ${env_file}."
  set_env_value "$env_file" TAIGA_SCHEME "$TAIGA_SCHEME"
  set_env_value "$env_file" TAIGA_DOMAIN "$TAIGA_DOMAIN"
  set_env_value "$env_file" SUBPATH "\"${TAIGA_SUBPATH}\""
  set_env_value "$env_file" WEBSOCKETS_SCHEME "$WEBSOCKETS_SCHEME"
  set_env_value "$env_file" SECRET_KEY "\"${secret_key}\""
  set_env_value "$env_file" POSTGRES_USER "taiga"
  set_env_value "$env_file" POSTGRES_PASSWORD "\"${postgres_password}\""
  set_env_value "$env_file" RABBITMQ_USER "taiga"
  set_env_value "$env_file" RABBITMQ_PASS "\"${rabbitmq_password}\""
  set_env_value "$env_file" RABBITMQ_VHOST "taiga"
  set_env_value "$env_file" RABBITMQ_ERLANG_COOKIE "\"${erlang_cookie}\""
  set_env_value "$env_file" ENABLE_TELEMETRY "False"

  chown "$SERVICE_USER:$SERVICE_GROUP" "$env_file"
  chmod 0600 "$env_file"
}

write_compose_override() {
  local override_file="${INSTALL_DIR}/docker-compose.override.yml"

  if [[ -e "$override_file" ]]; then
    log "Preserving existing Compose override ${override_file}."
    return
  fi

  log "Adding restart policies in ${override_file}."
  cat >"$override_file" <<'EOF'
# Managed initially by install-taiga.sh.
# Keeps Taiga containers running after individual process failures or daemon restarts.
services:
  taiga-db:
    restart: unless-stopped
  taiga-back:
    restart: unless-stopped
  taiga-async:
    restart: unless-stopped
  taiga-async-rabbitmq:
    restart: unless-stopped
  taiga-front:
    restart: unless-stopped
  taiga-events:
    restart: unless-stopped
  taiga-events-rabbitmq:
    restart: unless-stopped
  taiga-protected:
    restart: unless-stopped
  taiga-gateway:
    restart: unless-stopped
EOF
  chown "$SERVICE_USER:$SERVICE_GROUP" "$override_file"
  chmod 0640 "$override_file"
}

validate_compose_configuration() {
  log "Validating the merged Docker Compose configuration."
  run_compose config --quiet
}

systemd_escape_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

install_systemd_unit() {
  local unit_path="/etc/systemd/system/${SYSTEMD_UNIT}"
  local docker_path
  local quoted_home

  docker_path="$(command -v docker)"
  quoted_home="$(systemd_escape_value "HOME=${SERVICE_HOME}")"

  log "Installing systemd unit ${SYSTEMD_UNIT}."
  cat >"$unit_path" <<EOF
[Unit]
Description=Taiga Docker Compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=${quoted_home}
ExecStart=${docker_path} compose up -d --remove-orphans
ExecStop=${docker_path} compose stop
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$unit_path"
  log "Validating ${SYSTEMD_UNIT} with systemd-analyze."
  systemd-analyze verify "$unit_path"
  systemctl daemon-reload
  systemctl enable "$SYSTEMD_UNIT"
  systemctl reset-failed "$SYSTEMD_UNIT" 2>/dev/null || true
}

start_taiga() {
  log "Pulling Taiga container images. This can take several minutes."
  run_compose pull

  log "Starting Taiga through ${SYSTEMD_UNIT}."
  systemctl restart "$SYSTEMD_UNIT"
  systemctl is-active --quiet "$SYSTEMD_UNIT" ||
    die "${SYSTEMD_UNIT} did not reach the active state."

  run_compose ps
}

wait_for_taiga_stack() {
  local expected_services=(
    taiga-db
    taiga-back
    taiga-async
    taiga-async-rabbitmq
    taiga-front
    taiga-events
    taiga-events-rabbitmq
    taiga-protected
    taiga-gateway
  )
  local running_services
  local service
  local all_running
  local attempt
  local database_container
  local database_health

  log "Waiting for all Taiga containers to reach the running state."
  for attempt in {1..60}; do
    running_services="$(run_compose ps --services --status running 2>/dev/null || true)"
    all_running=1
    for service in "${expected_services[@]}"; do
      if ! grep -qx "$service" <<<"$running_services"; then
        all_running=0
        break
      fi
    done

    if (( all_running == 1 )); then
      break
    fi
    sleep 2
  done

  if (( all_running != 1 )); then
    run_compose ps || true
    run_compose logs --tail=100 || true
    die "One or more Taiga containers did not remain running."
  fi

  database_container="$(run_compose ps -q taiga-db)"
  [[ -n "$database_container" ]] || die "Could not locate the Taiga database container."

  log "Waiting for PostgreSQL to report healthy."
  for attempt in {1..60}; do
    database_health="$(
      run_as_service docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$database_container" 2>/dev/null || true
    )"
    if [[ "$database_health" == "healthy" ]]; then
      log "All Taiga containers are running and PostgreSQL is healthy."
      return
    fi
    sleep 2
  done

  run_compose ps || true
  run_compose logs --tail=100 taiga-db || true
  die "PostgreSQL did not become healthy."
}

maybe_create_superuser() {
  if ! confirm "Create the initial Taiga administrator now?" "yes"; then
    warn "Administrator creation skipped."
    return
  fi

  log "Starting Taiga's interactive administrator creation command."
  (
    cd "$INSTALL_DIR"
    run_as_service ./taiga-manage.sh createsuperuser
  )
}

show_completion() {
  local configured_url
  local saved_scheme
  local saved_domain
  local saved_subpath
  configured_url="$PUBLIC_URL"
  if [[ -z "$configured_url" && -r "${INSTALL_DIR}/.env" ]]; then
    saved_scheme="$(read_env_value "${INSTALL_DIR}/.env" TAIGA_SCHEME)"
    saved_domain="$(read_env_value "${INSTALL_DIR}/.env" TAIGA_DOMAIN)"
    saved_subpath="$(read_env_value "${INSTALL_DIR}/.env" SUBPATH)"
    if [[ -n "$saved_scheme" && -n "$saved_domain" ]]; then
      configured_url="${saved_scheme}://${saved_domain}${saved_subpath}"
    fi
  fi

  cat <<EOF

Taiga installation completed
============================

Installation directory : ${INSTALL_DIR}
Service account        : ${SERVICE_USER}
Service account home   : ${SERVICE_HOME}
Systemd unit           : ${SYSTEMD_UNIT}
Configured URL         : ${configured_url:-see ${INSTALL_DIR}/.env}
Installer log          : ${LOG_FILE}

Useful commands:

  sudo systemctl status ${SYSTEMD_UNIT}
  sudo systemctl restart ${SYSTEMD_UNIT}
  sudo su - ${SERVICE_USER}
  cd ${INSTALL_DIR}
  docker compose ps
  docker compose logs --tail=100

The service account has a locked password. Enter it only through sudo.

If HTTPS was configured, point your reverse proxy at this VM on TCP port 9000
and enable WebSocket forwarding before opening Taiga in a browser.

Back up both the Docker volumes and ${INSTALL_DIR}/.env. The .env file contains
credentials required to restore this installation.
EOF
}

read_env_value() {
  local file="$1"
  local key="$2"

  awk -v wanted_key="$key" '
    index($0, wanted_key "=") == 1 {
      value = substr($0, length(wanted_key) + 2)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$file"
}

main() {
  require_root_and_tty "${1:-}"
  load_and_validate_os
  show_intro
  ensure_debian_packages
  ensure_docker
  prompt_service_user
  ensure_service_user
  prompt_install_path
  check_install_capacity
  clone_taiga
  configure_taiga_env
  write_compose_override
  validate_compose_configuration
  install_systemd_unit
  start_taiga
  wait_for_taiga_stack
  maybe_create_superuser
  show_completion
}

main "$@"
