#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="0.1.1"
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

# ---------------- LOGGING ----------------

log_info(){ printf "[INFO] %s\n" "$*"; }
log_warn(){ printf "[WARN] %s\n" "$*" >&2; }
log_error(){ printf "[ERROR] %s\n" "$*" >&2; }

die(){ log_error "$1"; exit 1; }

trap 'log_error "Unexpected failure on line $LINENO"' ERR

# ---------------- PROXMOX STORAGE ----------------

get_storage_list() {
  pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}'
}

select_storage() {
  local list=()
  while read -r s; do [[ -n "$s" ]] && list+=("$s"); done < <(get_storage_list)

  [[ ${#list[@]} -eq 0 ]] && die "No usable LXC storage found."

  # explicitní volba přes -s/--storage se respektuje bez ptaní
  if [[ -n "$CT_STORAGE" ]]; then
    for s in "${list[@]}"; do
      if [[ "$s" == "$CT_STORAGE" ]]; then
        return
      fi
    done
    log_warn "Storage '$CT_STORAGE' not found."
  fi

  if [[ ${#list[@]} -eq 1 ]]; then
    CT_STORAGE="${list[0]}"
    log_info "Auto-selected storage: $CT_STORAGE"
    return
  fi

  echo
  echo "Available storage:"
  local i=1
  local type
  for s in "${list[@]}"; do
    type=$(pvesm status | awk -v x="$s" '$1==x {print $2}')
    echo "  $i) $s ($type)"
    ((i++))
  done

  echo

  while true; do
    read -r -p "Select storage [1]: " c
    c=${c:-1}
    [[ "$c" =~ ^[0-9]+$ ]] && ((c>=1 && c<=${#list[@]})) && break
    log_warn "Invalid choice"
  done

  CT_STORAGE="${list[$((c-1))]}"
  log_info "Selected storage: $CT_STORAGE"
}

# ---------------- ARGS ----------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--ctid) CTID="$2"; shift 2;;
      -n|--hostname) CT_HOSTNAME="$2"; shift 2;;
      -s|--storage) CT_STORAGE="$2"; shift 2;;
      -c|--cores) CT_CORES="$2"; shift 2;;
      -m|--memory) CT_MEMORY="$2"; shift 2;;
      -d|--disk) CT_DISK="$2"; shift 2;;
      -b|--bridge) CT_BRIDGE="$2"; shift 2;;
      --force) FORCE_RECREATE=1; shift;;
      -y|--yes) AUTO_CONFIRM=1; shift;;
      -h|--help) exit 0;;
      *) die "Unknown arg $1";;
    esac
  done
}

# ---------------- MAIN ----------------

main() {
  parse_args "$@"

  command -v pvesm >/dev/null || die "Not running on Proxmox"

  log_info "Installer v$SCRIPT_VERSION"

  select_storage

  echo
  log_info "Final storage: $CT_STORAGE"

  # tady pokračuje tvoje původní logika (nezměněná)
}

main "$@"
