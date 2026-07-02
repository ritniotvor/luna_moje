#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.1.0"
WEB_API_BASE="https://webshare.cz/api"
DEFAULT_STACK_SUBDIR="luna-docker"
AUTO_START=1
FORCE_DOWNLOAD=0

WS_USERNAME="${WS_USERNAME:-}"
WS_PASSWORD="${WS_PASSWORD:-}"
WS_PASSWORD_DIGEST=""
WS_LOGIN_DIGEST=""

SCRIPT_SOURCE="${BASH_SOURCE[0]-$0}"
REPO_ROOT=$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)
STACK_DIR=""
BIN_DIR=""
DOCKERFILE_PATH=""
COMPOSE_FILE_PATH=""
BINARY_PATH=""
LUNA_FILE_IDENT=""
LUNA_BINARY_NAME=""
LUNA_ARCH_LABEL=""

DOCKER_COMPOSE_CMD=()

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  local message=$1
  local code=${2:-1}
  log_error "$message"
  exit "$code"
}

usage() {
  cat <<'EOF'
Usage: luna-docker-compose.sh [options]

Options:
  -d, --stack-dir <path>   Directory where docker-compose assets are written (default: ./luna-docker)
      --no-up              Generate files only; skip docker compose up
      --force-download     Re-download the Luna binary even if it already exists locally
      --ws-user <user>     Webshare username (or set WS_USERNAME env)
      --ws-pass <pass>     Webshare password (or set WS_PASSWORD env)
  -h, --help               Show this message and exit
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--stack-dir)
        STACK_DIR="$2"
        shift 2
        ;;
      --no-up)
        AUTO_START=0
        shift
        ;;
      --force-download)
        FORCE_DOWNLOAD=1
        shift
        ;;
      --ws-user)
        WS_USERNAME="$2"
        shift 2
        ;;
      --ws-pass)
        WS_PASSWORD="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        usage
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_command() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' not found."
  done
}

select_luna_payload() {
  local arch=${1:-$(uname -m)}
  case "$arch" in
    x86_64|amd64)
      LUNA_FILE_IDENT="fr8hqGwwbN"
      LUNA_BINARY_NAME="luna-linux-amd64"
      LUNA_ARCH_LABEL="amd64"
      ;;
    i386|i486|i586|i686)
      LUNA_FILE_IDENT="jEGJZfnm3l"
      LUNA_BINARY_NAME="luna-linux-386"
      LUNA_ARCH_LABEL="386"
      ;;
    aarch64|arm64)
      LUNA_FILE_IDENT="MIZ5nvHLdx"
      LUNA_BINARY_NAME="luna-linux-arm64"
      LUNA_ARCH_LABEL="arm64"
      ;;
    armv6l|armv7l|armv8l|armv9l|armhf|arm)
      LUNA_FILE_IDENT="gcmeheY2Nn"
      LUNA_BINARY_NAME="luna-linux-arm"
      LUNA_ARCH_LABEL="arm"
      ;;
    *)
      die "Unsupported host architecture '$arch'. Supported: amd64, 386, arm64, arm."
      ;;
  esac
  log_info "Detected host architecture $arch -> payload $LUNA_BINARY_NAME"
}

prompt_credentials() {
  if [[ -z "$WS_USERNAME" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Webshare username: " WS_USERNAME
    else
      die "Missing Webshare username. Provide --ws-user or set WS_USERNAME."
    fi
  fi

  if [[ -z "$WS_PASSWORD" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "Webshare password: " WS_PASSWORD
      printf '\n'
    else
      die "Missing Webshare password. Provide --ws-pass or set WS_PASSWORD."
    fi
  fi

  if [[ -z "$WS_USERNAME" || -z "$WS_PASSWORD" ]]; then
    die "Webshare credentials cannot be empty."
  fi
}

sha1_hex() {
  printf '%s' "$1" | openssl dgst -sha1 | awk '{print $2}'
}

md5_hex() {
  printf '%s' "$1" | openssl dgst -md5 | awk '{print $2}'
}

xml_extract() {
  local xml=$1
  local tag=$2
  printf '%s' "$xml" | tr -d '\n' | sed -n "s:.*<$tag>\\([^<]*\\)</$tag>.*:\1:p"
}

fetch_webshare_salt() {
  local response status message salt
  response=$(curl -fsS -X POST "$WEB_API_BASE/salt/" \
    --data-urlencode "username_or_email=$WS_USERNAME") || die "Unable to reach Webshare salt endpoint."

  status=$(xml_extract "$response" status)
  if [[ "$status" != "OK" ]]; then
    message=$(xml_extract "$response" message)
    die "Salt request failed: ${message:-Unknown error}."
  fi

  salt=$(xml_extract "$response" salt)
  if [[ -z "$salt" ]]; then
    die "Salt response missing value."
  fi

  printf '%s' "$salt"
}

derive_webshare_digests() {
  local salt md5_crypt
  salt=$(fetch_webshare_salt)
  md5_crypt=$(openssl passwd -1 -salt "$salt" "$WS_PASSWORD" | tr -d '\n')
  WS_PASSWORD_DIGEST=$(sha1_hex "$md5_crypt")
  WS_LOGIN_DIGEST=$(md5_hex "$WS_USERNAME:Webshare:$WS_PASSWORD_DIGEST")
}

webshare_login() {
  local response status message token
  response=$(curl -fsS -X POST "$WEB_API_BASE/login/" \
    --data-urlencode "username_or_email=$WS_USERNAME" \
    --data-urlencode "password=$WS_PASSWORD_DIGEST" \
    --data-urlencode "digest=$WS_LOGIN_DIGEST" \
    --data-urlencode "keep_logged_in=1") || die "Unable to reach Webshare login endpoint."

  status=$(xml_extract "$response" status)
  if [[ "$status" != "OK" ]]; then
    message=$(xml_extract "$response" message)
    die "Webshare login failed: ${message:-Unknown error}."
  fi

  token=$(xml_extract "$response" token)
  if [[ -z "$token" ]]; then
    die "Webshare login response missing <token>."
  fi

  printf '%s' "$token"
}

request_download_link() {
  local token=$1
  local response link message status
  response=$(curl -fsS -X POST "$WEB_API_BASE/file_link/" \
    --data-urlencode "ident=$LUNA_FILE_IDENT" \
    --data-urlencode "wst=$token") || die "Unable to reach Webshare file_link endpoint."

  status=$(xml_extract "$response" status)
  if [[ "$status" != "OK" ]]; then
    message=$(xml_extract "$response" message)
    die "File link retrieval failed: ${message:-Unknown error}."
  fi

  link=$(xml_extract "$response" link)
  if [[ -z "$link" ]]; then
    die "File link response missing <link>."
  fi

  printf '%s' "$link"
}

resolve_stack_paths() {
  local target=${STACK_DIR:-$DEFAULT_STACK_SUBDIR}
  case "$target" in
    /*)
      STACK_DIR="$target"
      ;;
    *)
      STACK_DIR="$REPO_ROOT/$target"
      ;;
  esac

  mkdir -p "$STACK_DIR"
  STACK_DIR=$(cd "$STACK_DIR" && pwd)
  BIN_DIR="$STACK_DIR/bin"
  mkdir -p "$BIN_DIR"
  DOCKERFILE_PATH="$STACK_DIR/Dockerfile"
  COMPOSE_FILE_PATH="$STACK_DIR/docker-compose.yml"
}

download_luna_binary() {
  BINARY_PATH="$BIN_DIR/$LUNA_BINARY_NAME"
  if [[ -f "$BINARY_PATH" && $FORCE_DOWNLOAD -eq 0 ]]; then
    log_info "Binary $LUNA_BINARY_NAME already present at $BINARY_PATH (use --force-download to refresh)."
    return
  fi

  log_info "Downloading $LUNA_BINARY_NAME from Webshare.cz"
  derive_webshare_digests
  local token link tmp
  token=$(webshare_login)
  link=$(request_download_link "$token")
  tmp=$(mktemp)
  curl -fsSL "$link" -o "$tmp"
  chmod +x "$tmp"
  mv "$tmp" "$BINARY_PATH"
}

write_dockerfile() {
  cat <<EOF >"$DOCKERFILE_PATH"
# Generated by luna-docker-compose.sh v$SCRIPT_VERSION
FROM debian:12-slim

RUN apt-get update \\
  && apt-get install -y --no-install-recommends ca-certificates curl \\
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/luna
COPY bin/$LUNA_BINARY_NAME /opt/luna/$LUNA_BINARY_NAME
RUN chmod +x /opt/luna/$LUNA_BINARY_NAME

EXPOSE 7127 7126
ENTRYPOINT ["/opt/luna/$LUNA_BINARY_NAME", "--https"]
EOF
}

write_compose_file() {
  cat <<EOF >"$COMPOSE_FILE_PATH"
# Generated by luna-docker-compose.sh v$SCRIPT_VERSION
services:
  luna:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: luna-docker
    ports:
      - "0.0.0.0:7127:7127"
      - "0.0.0.0:7126:7126"
    restart: unless-stopped
EOF
}

resolve_docker_compose_command() {
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      DOCKER_COMPOSE_CMD=(docker compose)
      return
    fi
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD=(docker-compose)
    return
  fi

  die "Neither 'docker compose' nor 'docker-compose' is available. Install Docker Compose to continue."
}

docker_compose() {
  "${DOCKER_COMPOSE_CMD[@]}" "$@"
}

start_stack() {
  resolve_docker_compose_command
  log_info "Building and starting the Luna container via docker compose"
  docker_compose -f "$COMPOSE_FILE_PATH" up -d --build
}

summarize() {
  printf '\n'
  log_info "Docker assets ready in $STACK_DIR"
  printf '  Compose file: %s\n' "$COMPOSE_FILE_PATH"
  printf '  Dockerfile:   %s\n' "$DOCKERFILE_PATH"
  printf '  Binary:       %s (%s)\n' "$BINARY_PATH" "$LUNA_ARCH_LABEL"

  printf '\nRun the following commands to manage the stack:\n'
  printf '  cd "%s" && docker compose up -d --build\n' "$STACK_DIR"
  printf '  cd "%s" && docker compose down\n' "$STACK_DIR"
}

main() {
  parse_args "$@"
  require_command curl openssl sed awk tr uname mktemp
  resolve_stack_paths
  select_luna_payload
  prompt_credentials
  download_luna_binary
  write_dockerfile
  write_compose_file
  if [[ $AUTO_START -eq 1 ]]; then
    start_stack
  else
    log_warn "Skipping docker compose up due to --no-up."
  fi
  summarize
  unset WS_PASSWORD WS_USERNAME WS_PASSWORD_DIGEST WS_LOGIN_DIGEST
}

main "$@"
