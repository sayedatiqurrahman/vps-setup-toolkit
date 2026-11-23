#!/usr/bin/env bash
# common.sh - shared helpers for the VPS Setup Toolkit.
#
# This file is a library. It is sourced by the entry points and modules; it
# never performs an action by itself. All paths can be overridden with
# VPS_SETUP_* environment variables so the test suite can run unprivileged.

COMMON_LOADED=1

APP_NAME="vps-setup"
APP_VERSION="1.0.0"
TOOLKIT_NAME="VPS Setup Toolkit"

# Persistent state. /etc/default/vps-setup is kept for compatibility with the
# original complete-vps-setup-security-guide.md script.
CONF_FILE="${VPS_SETUP_CONF:-/etc/default/vps-setup}"
STATE_DIR="${VPS_SETUP_STATE_DIR:-/etc/vps-setup}"
LOG_DIR="${VPS_SETUP_LOG_DIR:-/var/log/vps-setup}"
LOG_FILE="${VPS_SETUP_LOG_FILE:-${LOG_DIR}/setup.log}"
BACKUP_DIR="${VPS_SETUP_BACKUP_DIR:-/var/backups/vps-setup}"
INBOUND_RULES_FILE="${VPS_SETUP_INBOUND_RULES:-${STATE_DIR}/host-inbound.rules}"
NFT_STATE_FILE="${VPS_SETUP_NFT_STATE:-${STATE_DIR}/nft-applied.rules}"

# Installed location and generated artifacts.
INSTALL_DIR="${VPS_SETUP_HOME:-/usr/local/lib/vps-setup-toolkit}"
WATCHER_PATH="${VPS_SETUP_WATCHER:-/usr/local/sbin/vps-firewall-watch}"
UNIT_PATH="${VPS_SETUP_UNIT:-/etc/systemd/system/vps-firewall-watch.service}"
UNIT_NAME="vps-firewall-watch.service"
WRAPPER_PATH="${VPS_SETUP_WRAPPER:-/usr/local/sbin/vps-setup}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || printf '.')"
SOURCE_ROOT="$(cd -- "${SCRIPT_DIR}/.." 2>/dev/null && pwd -P || printf '.')"

PKG_UPDATED=0
OS_ID="unknown"
OS_VERSION=""
OS_CODENAME=""
OS_PRETTY="unknown"
OS_ID_LIKE=""
OS_FAMILY="unknown"
OS_SUPPORTED=1
ARCH="unknown"
PKG_MANAGER="none"
INIT_SYSTEM="unknown"
OS_RELEASE_FILE="${VPS_SETUP_OS_RELEASE:-/etc/os-release}"

# ---------------------------------------------------------------------------
# Logging and user interaction
# ---------------------------------------------------------------------------

init_runtime(){
  mkdir -p -- "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
  chmod 0750 -- "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
  touch -- "$LOG_FILE" 2>/dev/null || true
  chmod 0640 -- "$LOG_FILE" 2>/dev/null || true
  return 0
}

_log_line(){
  local level="$1"; shift
  local line="[$(date '+%F %T')] [${level}] $*"
  if [[ "$level" == "INFO" ]]; then
    printf '%s\n' "$line"
  else
    printf '%s\n' "$line" >&2
  fi
  if [[ -w "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

log(){ _log_line INFO "$@"; }
warn(){ _log_line WARN "$@"; }
error(){ _log_line ERROR "$@"; }
success(){ _log_line OK "$@"; }
section(){ printf '\n===== %s =====\n' "$*"; }

die(){ error "$@"; exit 1; }

confirm(){
  local answer=""
  read -r -p "$1 [y/N]: " answer || return 1
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

confirm_typed(){
  local expected="$1" answer=""
  read -r -p "Type '${expected}' to confirm: " answer || return 1
  [[ "$answer" == "$expected" ]]
}

need_root(){
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run this toolkit as root (for example: sudo vps-setup)."
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# Resolve a repository-relative file from the source checkout first, then from
# the installed toolkit directory. This supports direct checkout execution,
# installed execution, and unit tests with an overridden source root.
toolkit_file(){
  local rel="$1"
  if [[ -n "${VPS_SETUP_SOURCE_ROOT:-}" && -f "${VPS_SETUP_SOURCE_ROOT}/${rel}" ]]; then
    printf '%s\n' "${VPS_SETUP_SOURCE_ROOT}/${rel}"
  elif [[ -f "${SOURCE_ROOT}/${rel}" ]]; then
    printf '%s\n' "${SOURCE_ROOT}/${rel}"
  else
    printf '%s\n' "${INSTALL_DIR}/${rel}"
  fi
}

command_exists(){ command -v "$1" >/dev/null 2>&1; }

is_systemd(){
  command_exists systemctl && [[ -d /run/systemd/system ]]
}

# A toolkit-managed watcher still needs a supervisor. systemd is preferred;
# cron is used as a portable fallback on non-systemd Linux systems.
detect_init_system(){
  if [[ -n "${VPS_SETUP_INIT_SYSTEM:-}" ]]; then
    INIT_SYSTEM="$VPS_SETUP_INIT_SYSTEM"
    return 0
  fi
  if is_systemd; then
    INIT_SYSTEM="systemd"
  elif command_exists rc-service; then
    INIT_SYSTEM="openrc"
  elif command_exists chkconfig || command_exists update-rc.d; then
    INIT_SYSTEM="sysv"
  else
    INIT_SYSTEM="unknown"
  fi
}

# ---------------------------------------------------------------------------
# OS / architecture detection
# ---------------------------------------------------------------------------

detect_os(){
  OS_ID="unknown"; OS_VERSION=""; OS_CODENAME=""; OS_PRETTY="unknown"
  OS_ID_LIKE=""; OS_FAMILY="unknown"; OS_SUPPORTED=1
  PKG_MANAGER="none"

  if [[ -r "$OS_RELEASE_FILE" ]]; then
    # /etc/os-release (or the test fixture) is a simple KEY=VALUE system file.
    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
  fi

  # Determine the distribution family from ID and ID_LIKE.
  local family_hint
  family_hint="$OS_ID $OS_ID_LIKE"
  case " $family_hint " in
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" raspbian "*) OS_FAMILY="debian" ;;
    *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*|*" amzn "*) OS_FAMILY="rhel" ;;
    *" suse "*|*" sles "*|*" opensuse "*) OS_FAMILY="suse" ;;
    *" arch "*|*" manjaro "*|*" endeavouros "*) OS_FAMILY="arch" ;;
    *" alpine "*) OS_FAMILY="alpine" ;;
    *) OS_FAMILY="unknown" ;;
  esac

  # Normalize architecture names across distributions.
  if command_exists dpkg; then
    ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  elif command_exists rpm; then
    ARCH="$(rpm --eval '%{_arch}' 2>/dev/null || uname -m)"
  else
    ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
    case "$ARCH" in
      x86_64|amd64) ARCH="amd64" ;;
      aarch64|arm64) ARCH="arm64" ;;
      armv7l|armv6l) ARCH="armhf" ;;
    esac
  fi

  # Prefer the native package manager of the detected family.
  case "$OS_FAMILY" in
    debian) PKG_MANAGER="apt" ;;
    rhel)
      if command_exists dnf; then PKG_MANAGER="dnf"
      elif command_exists yum; then PKG_MANAGER="yum"
      elif command_exists microdnf; then PKG_MANAGER="microdnf"
      fi ;;
    suse) PKG_MANAGER="zypper" ;;
    arch) PKG_MANAGER="pacman" ;;
    alpine) PKG_MANAGER="apk" ;;
  esac
  if [[ "$PKG_MANAGER" == "none" ]]; then
    for candidate in apt-get dnf yum apk pacman zypper; do
      if command_exists "$candidate"; then
        case "$candidate" in
          apt-get) PKG_MANAGER="apt" ;;
          *) PKG_MANAGER="$candidate" ;;
        esac
        break
      fi
    done
  fi
  detect_init_system
}

os_supported(){
  case "$OS_ID" in
    debian) [[ "$OS_VERSION" == "12" || "$OS_VERSION" == "13" ]] ;;
    ubuntu) [[ "$OS_VERSION" == "22.04" || "$OS_VERSION" == "24.04" ]] ;;
    *) return 1 ;;
  esac
}

require_linux(){
  local uname_s
  # VPS_SETUP_UNAME_S exists only so fixture-based tests can exercise this
  # guard on non-Linux development hosts.
  uname_s="${VPS_SETUP_UNAME_S:-$(uname -s 2>/dev/null || printf 'unknown')}"
  if [[ "$uname_s" != "Linux" ]]; then
    error "This toolkit manages Linux firewalls and packages; detected '${uname_s}'."
    return 1
  fi
  return 0
}

# Advisory check. Previously this aborted on non-Debian/Ubuntu systems; now it
# records OS_SUPPORTED and lets each module decide whether its operation is
# safe on the detected family. Dangerous OS-specific steps still require an
# explicit ALLOW_UNSUPPORTED_OS=1 opt-in.
require_supported_os(){
  require_linux || return 1
  detect_os
  if os_supported; then
    OS_SUPPORTED=1
  else
    OS_SUPPORTED=0
    warn "Detected ${OS_PRETTY} (${OS_ID} ${OS_VERSION}, ${ARCH}; family ${OS_FAMILY}, packages ${PKG_MANAGER}, init ${INIT_SYSTEM})."
    warn "This OS is not part of the primary Debian/Ubuntu test matrix; using best-effort ${PKG_MANAGER} support."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Package helpers
# ---------------------------------------------------------------------------

pkg_installed(){
  local pkg="$1"
  case "$PKG_MANAGER" in
    apt) command_exists dpkg && dpkg -s "$pkg" >/dev/null 2>&1 ;;
    dnf|yum|microdnf) command_exists rpm && rpm -q "$pkg" >/dev/null 2>&1 ;;
    apk) apk info -e "$pkg" >/dev/null 2>&1 ;;
    pacman) pacman -Qi "$pkg" >/dev/null 2>&1 ;;
    zypper) command_exists rpm && rpm -q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pkg_update_once(){
  if [[ "$PKG_UPDATED" -eq 0 ]]; then
    if [[ "$PKG_MANAGER" == "none" ]]; then
      warn "No supported package manager detected; skipping index update."
      return 0
    fi
    log "Updating ${PKG_MANAGER} package index."
    case "$PKG_MANAGER" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get update ;;
      dnf|yum|microdnf) "$PKG_MANAGER" -y makecache ;;
      apk) apk update ;;
      pacman) pacman -Sy ;;
      zypper) zypper --non-interactive refresh ;;
      *) return 0 ;;
    esac || return 1
    PKG_UPDATED=1
  fi
}

pkg_install(){
  local pkg ok=0 failed=0 status
  [[ $# -gt 0 ]] || return 0
  if [[ "$PKG_MANAGER" == "none" ]]; then
    error "No supported package manager detected. Install packages manually."
    return 1
  fi
  pkg_update_once || return 1
  for pkg in "$@"; do
    if pkg_installed "$pkg"; then
      ok=$((ok + 1))
      continue
    fi
    log "Installing package: ${pkg} (${PKG_MANAGER})"
    status=0
    case "$PKG_MANAGER" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" || status=$? ;;
      dnf|yum|microdnf) "$PKG_MANAGER" -y install "$pkg" || status=$? ;;
      apk) apk add --no-cache "$pkg" || status=$? ;;
      pacman) pacman -S --noconfirm --needed "$pkg" || status=$? ;;
      zypper) zypper --non-interactive install -y "$pkg" || status=$? ;;
      *) return 1 ;;
    esac
    if (( status == 0 )); then
      ok=$((ok + 1))
    else
      warn "Could not install '${pkg}' with ${PKG_MANAGER}; continuing."
      failed=$((failed + 1))
    fi
  done
  (( ok > 0 || failed == 0 )) || return 1
  return 0
}

# Compatibility aliases used by modules and external callers.
apt_update_once(){ pkg_update_once; }
apt_install(){ pkg_install "$@"; }

service_enable(){
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd) systemctl enable --now "$svc" ;;
    openrc) rc-update add "$svc" default && rc-service "$svc" start ;;
    sysv)
      if command_exists chkconfig; then chkconfig "$svc" on; else update-rc.d "$svc" defaults; fi
      service "$svc" start
      ;;
    *) warn "No supported init system; start '${svc}' manually."; return 1 ;;
  esac
}

service_reload(){
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd) systemctl reload "$svc" ;;
    openrc) rc-service "$svc" reload ;;
    sysv) service "$svc" reload ;;
    *) warn "Reload '${svc}' manually."; return 1 ;;
  esac
}

ssh_service_name(){
  local svc
  if command_exists systemctl && systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh.service'; then
    printf 'ssh\n'
  elif command_exists rc-service && rc-service -l 2>/dev/null | grep -qw sshd; then
    printf 'sshd\n'
  elif [[ -f /etc/init.d/sshd ]]; then
    printf 'sshd\n'
  else
    printf 'ssh\n'
  fi
}

# ---------------------------------------------------------------------------
# Backup / safe file installation
# ---------------------------------------------------------------------------

backup_file(){
  local file="$1" stamp dest
  [[ -e "$file" || -L "$file" ]] || return 0
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dest="${BACKUP_DIR}/${stamp}${file}"
  mkdir -p -- "$(dirname -- "$dest")" || return 1
  cp -a -- "$file" "$dest" || return 1
  log "Backup created: ${file} -> ${dest}"
}

# Install a file only when its content changes; always back up the old copy.
install_file(){
  local src="$1" dest="$2" mode="$3"
  [[ -f "$src" ]] || { error "Source file not found: $src"; return 1; }
  if [[ -f "$dest" ]] && cmp -s -- "$src" "$dest"; then
    return 0
  fi
  backup_file "$dest" || return 1
  mkdir -p -- "$(dirname -- "$dest")" || return 1
  install -m "$mode" -- "$src" "$dest" || return 1
  log "Installed ${dest} (mode ${mode})."
}

snapshot_firewall(){
  local dir
  dir="${BACKUP_DIR}/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p -- "$dir" || return 1
  if command_exists nft; then
    nft list ruleset >"${dir}/nftables.rules" 2>/dev/null || true
  fi
  if command_exists ufw; then
    ufw status verbose >"${dir}/ufw-status.txt" 2>/dev/null || true
  fi
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Validation helpers (pure functions, safe to use in tests)
# ---------------------------------------------------------------------------

valid_port(){
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

# Normalize a whitespace-separated list: validate every element, remove
# duplicates, strip leading zeroes and sort numerically. Output is a single
# line on stdout; errors go to stderr via die().
normalize_ports(){
  local input="$1" item out=""
  local -a nums=()
  for item in $input; do
    valid_port "$item" || die "Invalid port '${item}'. Valid range is 1-65535."
    item=$((10#$item))
    if [[ " ${nums[*]-} " == *" ${item} "* ]]; then
      continue
    fi
    nums+=("$item")
  done
  if (( ${#nums[@]} > 0 )); then
    out="$(printf '%s\n' "${nums[@]}" | sort -n | tr '\n' ' ')"
    out="${out% }"
  fi
  printf '%s' "$out"
}

valid_ipv4(){
  local ip="$1" a b c d octet
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  return 0
}

valid_ipv4_cidr(){
  local value="$1" ip prefix=""
  if [[ "$value" == */* ]]; then
    ip="${value%%/*}"
    prefix="${value#*/}"
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    (( 10#$prefix <= 32 )) || return 1
  else
    ip="$value"
  fi
  valid_ipv4 "$ip"
}

# Parse a comma-separated menu selection into the global array MENU_IDS.
# Duplicates are ignored and every id must be within 1..max_id.
MENU_IDS=()
MENU_PARSE_ERROR=""
parse_menu_selection(){
  local input="$1" max_id="${2:-13}" part
  local -a parts=()
  local seen=" "
  MENU_IDS=()
  MENU_PARSE_ERROR=""
  IFS=',' read -ra parts <<<"$input"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    if [[ -z "$part" ]]; then
      MENU_PARSE_ERROR="empty selection"
      return 1
    fi
    if [[ ! "$part" =~ ^[0-9]+$ ]]; then
      MENU_PARSE_ERROR="non-numeric selection '${part}'"
      return 1
    fi
    part=$((10#$part))
    if (( part < 1 || part > max_id )); then
      MENU_PARSE_ERROR="selection '${part}' is outside 1-${max_id}"
      return 1
    fi
    [[ "$seen" == *" ${part} "* ]] && continue
    seen+="${part} "
    MENU_IDS+=("$part")
  done
  (( ${#MENU_IDS[@]} > 0 )) || { MENU_PARSE_ERROR="no selection"; return 1; }
  return 0
}

list_contains(){
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Toggle and removal helpers for service ids. They operate on a
# space-separated id list and print the resulting normalized list.
toggle_id_list(){
  local current="$1" input="$2" item existing
  local -a ids=() kept=()
  local seen=" "
  for item in $current $input; do
    [[ "$item" =~ ^[0-9]+$ ]] || continue
    item=$((10#$item))
    if [[ "$seen" == *" ${item} "* ]]; then
      # Second occurrence: remove it (toggle behaviour).
      kept=()
      for existing in "${ids[@]}"; do
        [[ "$existing" == "$item" ]] || kept+=("$existing")
      done
      ids=("${kept[@]}")
      seen="${seen/ ${item} / }"
      continue
    fi
    seen+="${item} "
    ids+=("$item")
  done
  if (( ${#ids[@]} > 0 )); then
    printf '%s\n' "${ids[@]}" | sort -n | paste -sd' ' -
  fi
}

remove_id_list(){
  local current="$1" input="$2" item
  local -a removers=() kept=()
  for item in $input; do
    [[ "$item" =~ ^[0-9]+$ ]] && removers+=("$((10#$item))")
  done
  for item in $current; do
    list_contains "$item" "${removers[@]}" || kept+=("$item")
  done
  if (( ${#kept[@]} > 0 )); then
    printf '%s' "${kept[*]}"
  fi
}

# Read a boolean config value without executing arbitrary content.
config_bool(){
  local value="${1:-0}"
  [[ "$value" == "1" || "$value" =~ ^[Yy][Ee][Ss]$ || "$value" == "true" ]]
}

: "${COMMON_LOADED:=1}"
