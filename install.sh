#!/usr/bin/env bash
# install.sh - single entry point and secure bootstrap installer.
#
# Two modes:
#   1. Local checkout: copies this repository into /usr/local/lib and launches
#      the unified menu.
#   2. Remote bootstrap: no local files found (for example when piped from
#      curl), downloads a release/archive, optionally verifies SHA-256 and/or
#      GPG signature, then follows the same local install path.
#
# Verification is opt-in via environment variables because repository URLs
# differ between forks:
#   VPS_SETUP_ARCHIVE_URL, VPS_SETUP_ARCHIVE_SHA256,
#   VPS_SETUP_SIGNATURE_URL + VPS_SETUP_GPG_KEY_URL, VPS_SETUP_REF,
#   VPS_SETUP_REPO_URL.

set -Eeuo pipefail

APP_NAME="vps-setup"
APP_VERSION="1.0.0"
DEFAULT_REPO="https://github.com/sayedatiqurrahman/vps-setup-toolkit"
INSTALL_DIR="${VPS_SETUP_HOME:-/usr/local/lib/vps-setup-toolkit}"
WRAPPER_PATH="${VPS_SETUP_WRAPPER:-/usr/local/sbin/vps-setup}"

log(){ printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn(){ printf '\n[WARNING] %s\n' "$*" >&2; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run the installer as root: sudo bash install.sh"; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<USAGE
VPS Setup Toolkit installer v${APP_VERSION}

Usage:
  bash install.sh [--install-only] [--source-dir DIR] [--ref REF] [menu args...]
  curl -fsSL <installer-url> -o install.sh && sudo bash install.sh

Options:
  --install-only       Install files but do not launch the interactive menu.
  --source-dir DIR     Use a local checkout instead of downloading an archive.
  --ref REF            Git ref used for the GitHub archive (default: main).
  --help, --version    Show help or version.

Remaining arguments are passed to the toolkit menu (for example: status).
USAGE
}

INSTALL_ONLY=0
SOURCE_OPT=""
REF="${VPS_SETUP_REF:-main}"
MENU_ARGS=()

while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version|-V) printf '%s\n' "$APP_VERSION"; exit 0 ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    --source-dir)
      [[ $# -ge 2 ]] || die "--source-dir requires a path."
      SOURCE_OPT="$2"; shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || die "--ref requires a ref name."
      REF="$2"; shift 2
      ;;
    --) shift; MENU_ARGS+=("$@"); break ;;
    *) MENU_ARGS+=("$1"); shift ;;
  esac
done

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" 2>/dev/null && pwd -P || printf '.')"

backup_existing(){
  local file="$1" dest
  [[ -e "$file" || -L "$file" ]] || return 0
  dest="/var/backups/vps-setup/$(date '+%Y%m%d-%H%M%S')/${file}"
  mkdir -p -- "$(dirname -- "$dest")" 2>/dev/null || return 0
  cp -a -- "$file" "$dest" 2>/dev/null || true
}

find_source_root(){
  local candidate="$1"
  if [[ -f "${candidate}/scripts/common.sh" && -f "${candidate}/config/services.conf" && -f "${candidate}/menu.sh" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

bootstrap_download(){
  local repo archive tmp owner repo_name found
  command_exists curl || die "curl is required to bootstrap the toolkit."
  command_exists tar || die "tar is required to bootstrap the toolkit."

  repo="${VPS_SETUP_REPO_URL:-$DEFAULT_REPO}"
  if [[ -n "${VPS_SETUP_ARCHIVE_URL:-}" ]]; then
    archive="$VPS_SETUP_ARCHIVE_URL"
  elif [[ "$repo" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo_name="${BASH_REMATCH[2]%.git}"
    archive="https://codeload.github.com/${owner}/${repo_name}/tar.gz/refs/heads/${REF}"
  else
    die "Set VPS_SETUP_ARCHIVE_URL or use a https://github.com/OWNER/REPO VPS_SETUP_REPO_URL."
  fi

  tmp="$(mktemp -d)" || die "Cannot create a temporary directory."
  log "Downloading toolkit archive from ${archive}"
  curl -fsSL "$archive" -o "${tmp}/archive.tar.gz" || die "Archive download failed."

  if [[ -n "${VPS_SETUP_ARCHIVE_SHA256:-}" ]]; then
    local actual
    actual="$(sha256sum "${tmp}/archive.tar.gz" | awk '{print $1}')"
    [[ "${actual,,}" == "${VPS_SETUP_ARCHIVE_SHA256,,}" ]] || die "SHA-256 verification failed. Expected ${VPS_SETUP_ARCHIVE_SHA256}, got ${actual}."
    log "Archive SHA-256 verified."
  fi

  if [[ -n "${VPS_SETUP_SIGNATURE_URL:-}" || -n "${VPS_SETUP_GPG_KEY_URL:-}" ]]; then
    [[ -n "${VPS_SETUP_SIGNATURE_URL:-}" && -n "${VPS_SETUP_GPG_KEY_URL:-}" ]] || die "Set both VPS_SETUP_SIGNATURE_URL and VPS_SETUP_GPG_KEY_URL."
    command_exists gpg || die "gpg is required for signature verification."
    curl -fsSL "$VPS_SETUP_SIGNATURE_URL" -o "${tmp}/archive.sig" || die "Signature download failed."
    curl -fsSL "$VPS_SETUP_GPG_KEY_URL" -o "${tmp}/signing-key.asc" || die "Signing key download failed."
    gpg --no-default-keyring --keyring "${tmp}/keyring.gpg" --import "${tmp}/signing-key.asc" >/dev/null 2>&1 || die "Cannot import signing key."
    gpg --no-default-keyring --keyring "${tmp}/keyring.gpg" --verify "${tmp}/archive.sig" "${tmp}/archive.tar.gz" >/dev/null 2>&1 || die "GPG signature verification failed."
    log "Archive GPG signature verified."
  fi

  if [[ -z "${VPS_SETUP_ARCHIVE_SHA256:-}" && -z "${VPS_SETUP_SIGNATURE_URL:-}" ]]; then
    warn "No SHA-256 or GPG verification was configured for the downloaded archive."
    warn "For production use set VPS_SETUP_ARCHIVE_SHA256 (recommended) or both signature URLs."
  fi

  tar -xzf "${tmp}/archive.tar.gz" -C "$tmp" || die "Archive extraction failed."
  found="$(find "$tmp" -type f -path '*/scripts/common.sh' -print -quit)"
  [[ -n "$found" ]] || die "Downloaded archive does not contain scripts/common.sh."
  find_source_root "$(dirname "$(dirname "$found")")" || die "Downloaded archive has an unexpected layout."
}

SOURCE_ROOT=""
if [[ -n "$SOURCE_OPT" ]]; then
  SOURCE_ROOT="$(find_source_root "$SOURCE_OPT")" || die "No toolkit checkout found in ${SOURCE_OPT}."
elif SOURCE_ROOT="$(find_source_root "$SCRIPT_DIR")"; then
  :
elif SOURCE_ROOT="$(find_source_root "$PWD")"; then
  :
else
  SOURCE_ROOT="$(bootstrap_download)"
fi

need_root
log "Installing VPS Setup Toolkit ${APP_VERSION} into ${INSTALL_DIR}"
install -d -m 0755 -- "$INSTALL_DIR" || die "Cannot create ${INSTALL_DIR}."

for item in README.md LICENSE CHANGELOG.md install.sh menu.sh config scripts systemd docs complete-vps-setup-security-guide.md; do
  if [[ -e "${SOURCE_ROOT}/${item}" ]]; then
    cp -a -- "${SOURCE_ROOT}/${item}" "${INSTALL_DIR}/" || die "Failed to copy ${item}."
  fi
done
chmod 0755 "${INSTALL_DIR}/menu.sh" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
chmod 0755 "${INSTALL_DIR}"/scripts/*.sh 2>/dev/null || true

wrapper_tmp="$(mktemp)" || die "Cannot create wrapper file."
cat >"$wrapper_tmp" <<EOFWRAP
#!/usr/bin/env bash
# Generated by the VPS Setup Toolkit installer.
exec "${INSTALL_DIR}/menu.sh" "\$@"
EOFWRAP
backup_existing "$WRAPPER_PATH"
install -m 0755 -- "$wrapper_tmp" "$WRAPPER_PATH" || die "Cannot install ${WRAPPER_PATH}."
rm -f -- "$wrapper_tmp"

success(){ log "$*"; }
success "Installation complete. Run 'sudo vps-setup' at any time."

if [[ "$INSTALL_ONLY" == "1" || "${VPS_SETUP_INSTALL_ONLY:-0}" == "1" ]]; then
  exit 0
fi

exec "${INSTALL_DIR}/menu.sh" "${MENU_ARGS[@]}"
