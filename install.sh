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
APP_VERSION="1.1.2"
DEFAULT_REPO="https://github.com/sayedatiqurrahman/vps-setup-toolkit"
DEFAULT_REF="v1.1.2"
CHECKSUM_BRANCH="checksums"
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
  --ref REF            Git ref used for the GitHub archive (default: ${DEFAULT_REF}).
  --allow-unverified   Skip the published SHA-256 check (testing only).
  --help, --version    Show help or version.

The pinned default release is verified automatically against the SHA-256
published in the ${CHECKSUM_BRANCH} branch. Set VPS_SETUP_ARCHIVE_SHA256
when installing a custom ref/archive.

Remaining arguments are passed to the toolkit menu (for example: status).
USAGE
}

INSTALL_ONLY=0
ALLOW_UNVERIFIED=0
SOURCE_OPT=""
REF="${VPS_SETUP_REF:-$DEFAULT_REF}"
MENU_ARGS=()

while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version|-V) printf '%s\n' "$APP_VERSION"; exit 0 ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
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

BOOTSTRAP_SOURCE_ROOT=""

archive_sha256(){
  sha256sum "$1" | awk '{print $1}'
}

bootstrap_download(){
  local repo archive tmp owner repo_name found actual expected checksum_url ref_kind verified=0
  command_exists curl || die "curl is required to bootstrap the toolkit."
  command_exists tar || die "tar is required to bootstrap the toolkit."

  repo="${VPS_SETUP_REPO_URL:-$DEFAULT_REPO}"
  if [[ -n "${VPS_SETUP_ARCHIVE_URL:-}" ]]; then
    archive="$VPS_SETUP_ARCHIVE_URL"
  elif [[ "$repo" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo_name="${BASH_REMATCH[2]%.git}"
    # Version tags (v1.1.0, ...) live under refs/tags; branch names under heads.
    ref_kind="heads"
    [[ "$REF" =~ ^v[0-9] ]] && ref_kind="tags"
    archive="https://codeload.github.com/${owner}/${repo_name}/tar.gz/refs/${ref_kind}/${REF}"
  else
    die "Set VPS_SETUP_ARCHIVE_URL or use a https://github.com/OWNER/REPO VPS_SETUP_REPO_URL."
  fi

  tmp="$(mktemp -d)" || die "Cannot create a temporary directory."
  # This function is called from a command substitution; keep status output on
  # stderr so only the resolved source path is captured by the caller.
  log "Downloading toolkit archive from ${archive}" >&2
  if ! curl -fsSL "$archive" -o "${tmp}/archive.tar.gz" 2>/dev/null; then
    [[ -z "${VPS_SETUP_ARCHIVE_URL:-}" ]] || die "Archive download failed."
    # Fall back to the other ref namespace (tag <-> branch) before giving up.
    if [[ "$ref_kind" == "heads" ]]; then
      ref_kind="tags"
    else
      ref_kind="heads"
    fi
    archive="https://codeload.github.com/${owner}/${repo_name}/tar.gz/refs/${ref_kind}/${REF}"
    log "Retrying as a ${ref_kind} ref: ${archive}" >&2
    curl -fsSL "$archive" -o "${tmp}/archive.tar.gz" || die "Archive download failed."
  fi

  if [[ -n "${VPS_SETUP_ARCHIVE_SHA256:-}" ]]; then
    actual="$(archive_sha256 "${tmp}/archive.tar.gz")"
    [[ "${actual,,}" == "${VPS_SETUP_ARCHIVE_SHA256,,}" ]] || die "SHA-256 verification failed. Expected ${VPS_SETUP_ARCHIVE_SHA256}, got ${actual}."
    log "Archive SHA-256 verified against the supplied hash." >&2
    verified=1
  fi

  if [[ -n "${VPS_SETUP_SIGNATURE_URL:-}" || -n "${VPS_SETUP_GPG_KEY_URL:-}" ]]; then
    [[ -n "${VPS_SETUP_SIGNATURE_URL:-}" && -n "${VPS_SETUP_GPG_KEY_URL:-}" ]] || die "Set both VPS_SETUP_SIGNATURE_URL and VPS_SETUP_GPG_KEY_URL."
    command_exists gpg || die "gpg is required for signature verification."
    curl -fsSL "$VPS_SETUP_SIGNATURE_URL" -o "${tmp}/archive.sig" || die "Signature download failed."
    curl -fsSL "$VPS_SETUP_GPG_KEY_URL" -o "${tmp}/signing-key.asc" || die "Signing key download failed."
    gpg --no-default-keyring --keyring "${tmp}/keyring.gpg" --import "${tmp}/signing-key.asc" >/dev/null 2>&1 || die "Cannot import signing key."
    gpg --no-default-keyring --keyring "${tmp}/keyring.gpg" --verify "${tmp}/archive.sig" "${tmp}/archive.tar.gz" >/dev/null 2>&1 || die "GPG signature verification failed."
    log "Archive GPG signature verified." >&2
    verified=1
  fi

  # Default production path: verify automatically against the checksum
  # published for the pinned release. The checksum lives outside the archive
  # in a separate branch so it cannot be forged by editing the release itself.
  if (( verified == 0 )) && (( ALLOW_UNVERIFIED == 0 )) \
     && [[ "${VPS_SETUP_ALLOW_UNVERIFIED:-0}" != "1" ]] \
     && [[ -z "${VPS_SETUP_ARCHIVE_URL:-}" && "$repo" == "$DEFAULT_REPO" ]]; then
    checksum_url="https://raw.githubusercontent.com/${owner}/${repo_name}/${CHECKSUM_BRANCH}/${REF}.sha256"
    if curl -fsSL "$checksum_url" -o "${tmp}/expected.sha256" 2>/dev/null; then
      expected="$(awk 'NR==1 {print $1}' "${tmp}/expected.sha256")"
      [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] \
        || die "Invalid checksum published at ${checksum_url}."
      actual="$(archive_sha256 "${tmp}/archive.tar.gz")"
      [[ "${actual,,}" == "${expected,,}" ]] \
        || die "SHA-256 verification failed for ${REF}. Expected ${expected}, got ${actual}."
      log "Archive SHA-256 verified against the published checksum for ${REF}." >&2
      verified=1
    else
      die "No published SHA-256 checksum for ${REF} at ${checksum_url}. Use the pinned default release, set VPS_SETUP_ARCHIVE_SHA256, or pass --allow-unverified for testing."
    fi
  fi

  if (( verified == 0 )); then
    warn "No SHA-256 or GPG verification was configured for the downloaded archive."
    warn "For production use the pinned release (verified automatically) or set VPS_SETUP_ARCHIVE_SHA256."
  fi

  tar -xzf "${tmp}/archive.tar.gz" -C "$tmp" || die "Archive extraction failed."
  found="$(find "$tmp" -type f -path '*/scripts/common.sh' -print -quit)"
  [[ -n "$found" ]] || die "Downloaded archive does not contain scripts/common.sh."
  BOOTSTRAP_SOURCE_ROOT="$(find_source_root "$(dirname "$(dirname "$found")")")" \
    || die "Downloaded archive has an unexpected layout."
}

SOURCE_ROOT=""
if [[ -n "$SOURCE_OPT" ]]; then
  SOURCE_ROOT="$(find_source_root "$SOURCE_OPT")" || die "No toolkit checkout found in ${SOURCE_OPT}."
elif SOURCE_ROOT="$(find_source_root "$SCRIPT_DIR")"; then
  :
elif SOURCE_ROOT="$(find_source_root "$PWD")"; then
  :
else
  bootstrap_download
  SOURCE_ROOT="$BOOTSTRAP_SOURCE_ROOT"
fi

need_root
log "Installing VPS Setup Toolkit ${APP_VERSION} into ${INSTALL_DIR}"
install -d -m 0755 -- "$INSTALL_DIR" || die "Cannot create ${INSTALL_DIR}."

for item in README.md LICENSE CHANGELOG.md install.sh menu.sh config scripts systemd docs complete-vps-setup-security-guide.md; do
  if [[ -e "${SOURCE_ROOT}/${item}" ]]; then
    cp -a -- "${SOURCE_ROOT}/${item}" "${INSTALL_DIR}/" || die "Failed to copy ${item}."
  fi
done

# Never report success unless the files the wrapper actually executes exist.
for required in menu.sh install.sh scripts/common.sh config/services.conf; do
  [[ -f "${INSTALL_DIR}/${required}" ]] \
    || die "Installation is incomplete: ${required} is missing from ${INSTALL_DIR}. Source was ${SOURCE_ROOT}."
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
