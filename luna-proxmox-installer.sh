#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.1.0"
WEB_API_BASE="https://webshare.cz/api"
LUNA_FILE_IDENT=""
LUNA_BINARY_NAME=""
LUNA_ARCH_LABEL=""
DEFAULT_TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
DEFAULT_HOSTNAME="luna"
DEFAULT_CORES=1
DEFAULT_MEMORY=128
DEFAULT_DISK=2
DEFAULT_BRIDGE="vmbr0"
DEFAULT_SWAP=0

CTID=""
CT_HOSTNAME="$DEFAULT_HOSTNAME"
CT_STORAGE=""
CT_CORES="$DEFAULT_CORES"
CT_MEMORY="$DEFAULT_MEMORY"
CT_DISK="$DEFAULT_DISK"
CT_TEMPLATE="$DEFAULT_TEMPLATE"
CT_BRIDGE="$DEFAULT_BRIDGE"
AUTO_CONFIRM=0
FORCE_RECREATE=0

WS_USERNAME="${WS_USERNAME:-}"
WS_PASSWORD="${WS_PASSWORD:-}"
WS_PASSWORD_DIGEST=""
WS_LOGIN_DIGEST=""

if [[ -t 1 ]]; then
  COLOR_INFO='\033[1;34m'
  COLOR_WARN='\033[1;33m'
  COLOR_ERR='\033[1;31m'
  COLOR_RESET='\033[0m'
else
  COLOR_INFO=''
  COLOR_WARN=''
  COLOR_ERR=''
  COLOR_RESET=''
fi

log_info() {
  printf "%b[INFO]%b %s\n" "$COLOR_INFO" "$COLOR_RESET" "$*"
}

log_warn() {
  printf "%b[WARN]%b %s\n" "$COLOR_WARN" "$COLOR_RESET" "$*" >&2
}

log_error() {
  printf "%b[ERROR]%b %s\n" "$COLOR_ERR" "$COLOR_RESET" "$*" >&2
}

die() {
  local message=$1
  local code=${2:-1}
  log_error "$message"
  exit "$code"
}

handle_err() {
  local line=$1
  log_error "Unexpected failure on line ${line}. Check previous output for details."
}

trap 'handle_err ${LINENO}' ERR

usage() {
  cat <<'EOF'
Usage: luna-proxmox-installer.sh [options]

Options:
  -i, --ctid <id>          Explicit container ID (default: next free ID)
  -n, --hostname <name>    LXC hostname (default: luna)
  -s, --storage <name>     Proxmox storage for rootfs (default: prompts interactively)
  -c, --cores <count>      CPU cores (default: 1)
  -m, --memory <mb>        RAM in MB (default: 128)
  -d, --disk <gb>          Root disk size in GB (default: 2)
  -b, --bridge <bridge>    Proxmox bridge for net0 (default: vmbr0)
  -t, --template <ref>     LXC template (default: local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst)
      --ws-user <user>     Webshare username (fallback to WS_USERNAME env)
      --ws-pass <pass>     Webshare password (fallback to WS_PASSWORD env)
      --force              Destroy existing CTID before re-creating
  -y, --yes                Do not prompt for confirmation
  -h, --help               Show this message

Environment overrides:
  WS_USERNAME              Default Webshare username
  WS_PASSWORD              Default Webshare password
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--ctid)
        CTID="$2"
        shift 2
        ;;
      -n|--hostname)
        CT_HOSTNAME="$2"
        shift 2
        ;;
      -s|--storage)
        CT_STORAGE="$2"
        shift 2
        ;;
      -c|--cores)
        CT_CORES="$2"
        shift 2
        ;;
      -m|--memory)
        CT_MEMORY="$2"
        shift 2
        ;;
      -d|--disk)
        CT_DISK="$2"
        shift 2
        ;;
      -b|--bridge)
        CT_BRIDGE="$2"
        shift 2
        ;;
      -t|--template)
        CT_TEMPLATE="$2"
        shift 2
        ;;
      --ws-user)
        WS_USERNAME="$2"
        shift 2
        ;;
      --ws-pass)
        WS_PASSWORD="$2"
        shift 2
        ;;
      --force)
        FORCE_RECREATE=1
        shift
        ;;
      -y|--yes)
        AUTO_CONFIRM=1
        shift
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

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    die "This installer must run as root on the Proxmox host."
  fi
}

require_command() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' not found."
  done
}

assert_proxmox() {
  command -v pveversion >/dev/null 2>&1 || die "pveversion not found. Execute on a Proxmox VE node."
}

compute_default_ctid() {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid 2>/dev/null | tr -d '\n' | sed '/^$/d'
    return
  fi

  local last
  last=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -n1)
  if [[ -z "$last" ]]; then
    echo 100
  else
    echo $((last + 1))
  fi
}

get_storage_list() {
  pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}'
}

select_storage() {
  local list=()
  while read -r s; do [[ -n "$s" ]] && list+=("$s"); done < <(get_storage_list)

  [[ ${#list[@]} -eq 0 ]] && die "No usable LXC storage found."

  # explicitní volba přes -s/--storage se respektuje bez ptaní
  if [[ -n "$CT_STORAGE" ]]; then
    local s
    for s in "${list[@]}"; do
      if [[ "$s" == "$CT_STORAGE" ]]; then
        return
      fi
    done
    log_warn "Storage '$CT_STORAGE' not found."
  fi

  echo
  echo "Available storage:"
  local i=1
  local type s
  for s in "${list[@]}"; do
    type=$(pvesm status | awk -v x="$s" '$1==x {print $2}')
    echo "  $i) $s ($type)"
    ((i++))
  done

  echo

  local c
  while true; do
    read -r -p "Select storage [1]: " c
    c=${c:-1}
    [[ "$c" =~ ^[0-9]+$ ]] && ((c>=1 && c<=${#list[@]})) && break
    log_warn "Invalid choice"
  done

  CT_STORAGE="${list[$((c-1))]}"
  log_info "Selected storage: $CT_STORAGE"
}

confirm_plan() {
  cat <<EOF
Planned LXC deployment:
  CTID:       $CTID
  Hostname:   $CT_HOSTNAME
  Template:   $CT_TEMPLATE
  Storage:    $CT_STORAGE ($(format_disk_display))
  CPU / RAM:  $CT_CORES cores / $CT_MEMORY MB
  Bridge:     $CT_BRIDGE
  Payload:    $LUNA_BINARY_NAME (ident $LUNA_FILE_IDENT, arch $LUNA_ARCH_LABEL)
EOF
  if [[ $AUTO_CONFIRM -eq 0 ]]; then
    read -r -p "Proceed with creation? [y/N] " reply
    if [[ ! $reply =~ ^[Yy]$ ]]; then
      die "Aborted by user."
    fi
  fi
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

ensure_template() {
  local template="$1"
  if [[ $template != *:vztmpl/* ]]; then
    die "Template must resemble <storage>:vztmpl/<file>."
  fi

  local storage=${template%%:*}
  local filename=${template#*:vztmpl/}
  local cache_path="/var/lib/vz/template/cache/${filename}"

  if [[ -f "$cache_path" ]]; then
    log_info "Template $filename already cached."
    return
  fi

  log_info "Downloading template $filename into storage $storage..."
  pveam update >/dev/null
  if ! pveam available --section system | awk 'NR>1 {print $2}' | grep -Fxq "$filename"; then
    if [[ "$filename" == debian-12-standard_* ]]; then
      local fallback
      fallback=$(pveam available --section system | awk 'NR>1 {print $2}' | grep -E '^debian-12-standard_.*amd64\.tar\.zst$' | sort -V | tail -n1)
      if [[ -n "$fallback" ]]; then
        log_warn "Template $filename no longer published. Falling back to $fallback."
        filename="$fallback"
        CT_TEMPLATE="${storage}:vztmpl/${filename}"
        cache_path="/var/lib/vz/template/cache/${filename}"
      else
        die "Template $filename not available upstream and no fallback detected."
      fi
    else
      die "Template $filename not available upstream."
    fi
  fi

  if [[ -f "$cache_path" ]]; then
    log_info "Template $filename already cached after fallback."
    return
  fi

  pveam download "$storage" "$filename"
}

handle_existing_container() {
  if pct status "$CTID" &>/dev/null; then
    if [[ $FORCE_RECREATE -eq 0 ]]; then
      die "Container ID $CTID already exists. Use --force to recreate."
    fi

    log_warn "Container $CTID exists. Stopping and destroying per --force."
    if pct status "$CTID" | grep -q running; then
      pct stop "$CTID" >/dev/null
    fi
    pct destroy "$CTID" >/dev/null
  fi
}

prompt_credentials() {
  if [[ -z "$WS_USERNAME" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Webshare username: " WS_USERNAME
    else
      die "Missing Webshare username. Provide via --ws-user or WS_USERNAME env."
    fi
  fi

  if [[ -z "$WS_PASSWORD" ]]; then
    if [[ -t 0 ]]; then
      read -r -s -p "Webshare password: " WS_PASSWORD
      printf '\n'
    else
      die "Missing Webshare password. Provide via --ws-pass or WS_PASSWORD env."
    fi
  fi

  if [[ -z "$WS_USERNAME" || -z "$WS_PASSWORD" ]]; then
    die "Webshare credentials cannot be empty."
  fi
}

format_disk_display() {
  if [[ "$CT_DISK" =~ ^[0-9]+$ ]]; then
    printf '%s GB' "$CT_DISK"
  else
    printf '%s' "$CT_DISK"
  fi
}

validate_disk_size() {
  if [[ ! "$CT_DISK" =~ ^[0-9]+([kKmMgGtT])?$ ]]; then
    die "Disk size must be digits optionally followed by K/M/G/T (examples: 2, 4G, 2048M)."
  fi
}

sha1_hex() {
  printf '%s' "$1" | sha1sum | awk '{print $1}'
}

md5_hex() {
  printf '%s' "$1" | md5sum | awk '{print $1}'
}

fetch_webshare_salt() {
  local response status message salt
  response=$(curl -fsS -X POST "$WEB_API_BASE/salt/" \
    --data-urlencode "username_or_email=$WS_USERNAME") || die "Unable to reach Webshare salt endpoint."

  status=$(xml_extract "$response" status)
  if [[ "$status" != "OK" ]]; then
    message=$(xml_extract "$response" message)
    die "Unable to fetch Webshare salt: ${message:-Unknown error}."
  fi

  salt=$(xml_extract "$response" salt)
  if [[ -z "$salt" ]]; then
    die "Webshare salt response missing <salt> element."
  fi

  printf '%s' "$salt"
}

derive_webshare_digests() {
  local salt md5_crypt password_digest login_digest
  salt=$(fetch_webshare_salt)
  md5_crypt=$(openssl passwd -1 -salt "$salt" "$WS_PASSWORD" | tr -d '\n')
  password_digest=$(sha1_hex "$md5_crypt")
  login_digest=$(md5_hex "$WS_USERNAME:Webshare:$password_digest")

  WS_PASSWORD_DIGEST="$password_digest"
  WS_LOGIN_DIGEST="$login_digest"
}

xml_extract() {
  local xml=$1
  local tag=$2
  printf '%s' "$xml" | tr -d '\n' | sed -n "s:.*<$tag>\\([^<]*\\)</$tag>.*:\1:p"
}

verify_webshare_credentials() {
  log_info "Verifying Webshare.cz credentials..."
  derive_webshare_digests
  local response status message
  response=$(curl -fsS -X POST "$WEB_API_BASE/login/" \
    --data-urlencode "username_or_email=$WS_USERNAME" \
    --data-urlencode "password=$WS_PASSWORD_DIGEST" \
    --data-urlencode "digest=$WS_LOGIN_DIGEST" \
    --data-urlencode "keep_logged_in=1") || die "Unable to reach Webshare API."

  status=$(xml_extract "$response" status)
  if [[ "$status" != "OK" ]]; then
    message=$(xml_extract "$response" message)
    die "Webshare login failed: ${message:-Unknown error}."
  fi
  log_info "Webshare credentials accepted."
}

generate_password() {
  local pool=""
  while [[ ${#pool} -lt 20 ]]; do
    pool+=$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${pool:0:20}"
}

create_container() {
  log_info "Creating container $CTID from $CT_TEMPLATE"
  local net="name=eth0,bridge=${CT_BRIDGE},ip=dhcp,ip6=auto,firewall=1"
  ROOT_PASSWORD=$(generate_password)

  pct create "$CTID" "$CT_TEMPLATE" \
    --ostype debian \
    --hostname "$CT_HOSTNAME" \
    --password "$ROOT_PASSWORD" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$DEFAULT_SWAP" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "$net" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --start 0 >/dev/null

  pct set "$CTID" --onboot 1 >/dev/null
  log_info "Container $CTID created."
}

start_container() {
  log_info "Starting container $CTID"
  pct start "$CTID" >/dev/null
  sleep 5
}

sync_root_password() {
  log_info "Syncing root password inside container..."
  pct exec "$CTID" -- chpasswd <<EOF
root:$ROOT_PASSWORD
EOF
}

apt_prepare_container() {
  log_info "Installing prerequisites inside container..."
  pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8 bash -c "set -Eeuo pipefail; apt-get update >/dev/null; apt-get install -y ca-certificates curl openssl >/dev/null"
}

build_bootstrap_script() {
  local target=$1
  cat <<EOF >"$target"
#!/usr/bin/env bash
set -Eeuo pipefail

API_BASE="$WEB_API_BASE"
FILE_IDENT="$LUNA_FILE_IDENT"
BINARY_NAME="$LUNA_BINARY_NAME"
INSTALL_DIR="/opt/luna"
RUNNER_PATH="/usr/local/bin/luna-runner.sh"

WS_USERNAME="\${WS_USERNAME:-}"
WS_PASSWORD="\${WS_PASSWORD:-}"
PASSWORD_DIGEST=""
LOGIN_DIGEST=""

log() {
  printf "[luna-bootstrap] %s\\n" "\$*"
}

xml_extract() {
  local xml=\$1
  local tag=\$2
  printf '%s' "\$xml" | tr -d '\\n' | sed -n "s:.*<\$tag>\\\\([^<]*\\\\)</\$tag>.*:\\1:p"
}

fail() {
  log "\$1"
  exit 1
}

sha1_hex() {
  printf '%s' "\$1" | sha1sum | awk '{print \$1}'
}

md5_hex() {
  printf '%s' "\$1" | md5sum | awk '{print \$1}'
}

fetch_salt() {
  local response status message salt
  response=\$(curl -fsS -X POST "\$API_BASE/salt/" \\
    --data-urlencode "username_or_email=\$WS_USERNAME") || fail "Unable to reach salt endpoint."

  status=\$(xml_extract "\$response" status)
  if [[ "\$status" != "OK" ]]; then
    message=\$(xml_extract "\$response" message)
    fail "Salt request failed: \${message:-Unknown error}."
  fi

  salt=\$(xml_extract "\$response" salt)
  if [[ -z "\$salt" ]]; then
    fail "Salt response missing value."
  fi

  printf '%s' "\$salt"
}

derive_hashes() {
  local salt md5_crypt
  salt=\$(fetch_salt)
  md5_crypt=\$(openssl passwd -1 -salt "\$salt" "\$WS_PASSWORD" | tr -d '\\n')
  PASSWORD_DIGEST=\$(sha1_hex "\$md5_crypt")
  LOGIN_DIGEST=\$(md5_hex "\$WS_USERNAME:Webshare:\$PASSWORD_DIGEST")
}

if [[ -z "\$WS_USERNAME" || -z "\$WS_PASSWORD" ]]; then
  fail "Missing Webshare credentials in environment."
fi

derive_hashes

login_response=\$(curl -fsS -X POST "\$API_BASE/login/" \\
  --data-urlencode "username_or_email=\$WS_USERNAME" \\
  --data-urlencode "password=\$PASSWORD_DIGEST" \\
  --data-urlencode "digest=\$LOGIN_DIGEST" \\
  --data-urlencode "keep_logged_in=1")

login_status=\$(xml_extract "\$login_response" status)
if [[ "\$login_status" != "OK" ]]; then
  login_message=\$(xml_extract "\$login_response" message)
  fail "Login failed: \${login_message:-Unknown error}."
fi

login_token=\$(xml_extract "\$login_response" token)
if [[ -z "\$login_token" ]]; then
  fail "Login succeeded but token missing."
fi

link_response=\$(curl -fsS -X POST "\$API_BASE/file_link/" \\
  --data-urlencode "ident=\$FILE_IDENT" \\
  --data-urlencode "wst=\$login_token")

download_link=\$(xml_extract "\$link_response" link)
if [[ -z "\$download_link" ]]; then
  fail "Failed to acquire download link."
fi

install_tmp=\$(mktemp)
trap 'rm -f "\$install_tmp"' EXIT
mkdir -p "\$INSTALL_DIR"
chmod 755 "\$INSTALL_DIR"

log "Downloading Luna binary..."
curl -fsSL "\$download_link" -o "\$install_tmp"
install_path="\$INSTALL_DIR/\$BINARY_NAME"
rm -f "\$install_path"
chmod +x "\$install_tmp"
mv "\$install_tmp" "\$install_path"

cat <<RUNNER >"\$RUNNER_PATH"
#!/usr/bin/env bash
set -Eeuo pipefail
exec /opt/luna/\${BINARY_NAME} --https
RUNNER
chmod +x "\$RUNNER_PATH"

cat <<'UNIT' >/etc/systemd/system/luna.service
[Unit]
Description=Luna HTTPS proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/luna
ExecStart=/usr/local/bin/luna-runner.sh
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

# Proxmox LXC console autologin (matches community-scripts behaviour)
mkdir -p /etc/systemd/system/container-getty@1.service.d
cat <<'AUTOLOGIN' >/etc/systemd/system/container-getty@1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,38400,9600 tty%I linux
AUTOLOGIN

systemctl daemon-reload
systemctl enable --now luna.service
systemctl restart container-getty@1.service >/dev/null 2>&1 || true

unset WS_USERNAME
unset WS_PASSWORD
unset PASSWORD_DIGEST
unset LOGIN_DIGEST
log "Provisioning complete."
EOF
}

bootstrap_container() {
  log_info "Bootstrapping Luna payload inside container..."
  local bootstrap_file
  bootstrap_file=$(mktemp)
  build_bootstrap_script "$bootstrap_file"
  pct push "$CTID" "$bootstrap_file" /root/luna-bootstrap.sh >/dev/null
  rm -f "$bootstrap_file"
  pct exec "$CTID" -- chmod +x /root/luna-bootstrap.sh
  pct exec "$CTID" -- env LC_ALL=C.UTF-8 LANG=C.UTF-8 WS_USERNAME="$WS_USERNAME" WS_PASSWORD="$WS_PASSWORD" bash -c '/root/luna-bootstrap.sh'
  pct exec "$CTID" -- rm -f /root/luna-bootstrap.sh
}

check_service() {
  log_info "Validating systemd service state..."
  pct exec "$CTID" -- systemctl is-enabled luna.service >/dev/null
  pct exec "$CTID" -- systemctl is-active luna.service >/dev/null
}

summarize() {
  local ip
  ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  printf '\n'
  log_info "LXC container $CTID ready."
  [[ -n "$ip" ]] && printf "  Container IP: %s\n" "$ip"
  printf "  Hostname:    %s\n" "$CT_HOSTNAME"
  printf "  Root pass:   %s\n" "$ROOT_PASSWORD"
  printf "  Service:     systemctl status luna (inside container)\n"
  printf '\nNext steps:\n'
  printf "  pct enter %s -- journalctl -u luna -f\n" "$CTID"
}

main() {
  parse_args "$@"
  require_root
  require_command pct pveam pveversion pvesm curl awk sed tr mktemp openssl sha1sum md5sum
  assert_proxmox
  log_info "Luna installer v$SCRIPT_VERSION"

  select_luna_payload

  if [[ -z "$LUNA_FILE_IDENT" || -z "$LUNA_BINARY_NAME" ]]; then
    die "Failed to map host architecture to a Luna artifact."
  fi

  if [[ -z "$CTID" ]]; then
    CTID=$(compute_default_ctid)
  fi

  select_storage
  prompt_credentials
  validate_disk_size
  verify_webshare_credentials
  confirm_plan
  ensure_template "$CT_TEMPLATE"
  handle_existing_container
  create_container
  start_container
  sync_root_password
  apt_prepare_container
  bootstrap_container
  check_service
  summarize
  unset WS_PASSWORD
}

main "$@"
