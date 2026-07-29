#!/usr/bin/env bash
# Secure interactive Docker Engine installer
#
# Official Docker CE repository targets supported by this script:
#   - Debian
#   - Ubuntu
#   - RHEL
#   - CentOS Stream
#   - Fedora
#
# The script intentionally refuses unknown or derivative distributions rather
# than guessing a repository. It displays the detected server information and
# requires explicit confirmation before making changes.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly SCRIPT_VERSION="2.1.0"
readonly DIVIDER="-------------------------------------------------------------------------"

# Docker's APT signing-key fingerprint. A future legitimate key rotation will
# make this installer stop securely until this value is reviewed and updated.
readonly EXPECTED_APT_KEY_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# Docker's RPM signing-key fingerprint documented for RHEL/CentOS/Fedora.
readonly EXPECTED_RPM_KEY_FINGERPRINT="060A61C51B558A7F742B77AAC52FEB6B621E9F35"

readonly DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

SUDO=()
TMP_DIR=""
BACKUP_DIR=""
OS_FAMILY=""
DOCKER_REPO_DIST=""
DOCKER_REPO_BASE=""
OS_CODENAME=""
OS_NAME=""
OS_ID=""
OS_VERSION_ID=""
OS_VERSION_MAJOR=""
TARGET_ARCH=""
INSTALL_MODE="fresh"

print_divider() {
  printf '%s\n' "$DIVIDER"
}

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fatal() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

on_error() {
  local exit_code=$?
  local line_number=${1:-unknown}
  printf '[ERROR] Installation failed near line %s (exit code %s).\n' \
    "$line_number" "$exit_code" >&2
  exit "$exit_code"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

confirm_exact() {
  local message=$1
  local expected=$2
  local answer=""

  printf '%s\n' "$message"
  printf 'Type %s to continue: ' "$expected"
  IFS= read -r answer

  [[ "$answer" == "$expected" ]] || fatal "Cancelled by user."
}

ask_yes_no() {
  local prompt=$1
  local default_answer=${2:-N}
  local answer=""

  printf '%s ' "$prompt"
  IFS= read -r answer
  answer=${answer:-$default_answer}

  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

setup_privileges() {
  if (( EUID == 0 )); then
    SUDO=()
  else
    require_command sudo
    info "Validating sudo access..."
    sudo -v
    SUDO=(sudo)
  fi
}

prepare_workspace() {
  TMP_DIR=$(mktemp -d -t docker-secure-install.XXXXXXXX)
  chmod 0700 "$TMP_DIR"

  BACKUP_DIR="/etc/docker-install-backup-$(date -u +%Y%m%dT%H%M%SZ)"
}

load_os_information() {
  [[ -r /etc/os-release ]] || fatal "/etc/os-release is missing. OS detection cannot continue safely."

  # shellcheck disable=SC1091
  source /etc/os-release

  OS_ID=${ID:-}
  OS_NAME=${PRETTY_NAME:-${NAME:-unknown}}
  OS_VERSION_ID=${VERSION_ID:-}
  OS_VERSION_MAJOR=${OS_VERSION_ID%%.*}

  [[ -n "$OS_ID" ]] || fatal "ID is missing from /etc/os-release."
  [[ -n "$OS_VERSION_ID" ]] || fatal "VERSION_ID is missing from /etc/os-release."

  case "$OS_ID" in
    debian)
      OS_FAMILY="apt"
      DOCKER_REPO_DIST="debian"
      OS_CODENAME=${VERSION_CODENAME:-}
      ;;
    ubuntu)
      OS_FAMILY="apt"
      DOCKER_REPO_DIST="ubuntu"
      OS_CODENAME=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
      ;;
    rhel)
      OS_FAMILY="rpm"
      DOCKER_REPO_DIST="rhel"
      ;;
    centos)
      OS_FAMILY="rpm"
      DOCKER_REPO_DIST="centos"
      ;;
    fedora)
      OS_FAMILY="rpm"
      DOCKER_REPO_DIST="fedora"
      ;;
    *)
      fatal "Unsupported distribution: $OS_NAME. This installer only uses Docker's official Debian, Ubuntu, RHEL, CentOS, and Fedora repositories."
      ;;
  esac

  if [[ "$OS_FAMILY" == "apt" && -z "$OS_CODENAME" ]]; then
    fatal "The Debian/Ubuntu release codename could not be determined."
  fi

  DOCKER_REPO_BASE="https://download.docker.com/linux/$DOCKER_REPO_DIST"
  TARGET_ARCH=$(uname -m)
}

check_basic_compatibility() {
  require_command uname
  require_command hostname

  case "$TARGET_ARCH" in
    x86_64|amd64|aarch64|arm64|armv7l|ppc64le|s390x)
      ;;
    *)
      fatal "Unsupported or unverified CPU architecture: $TARGET_ARCH"
      ;;
  esac

  if ! command -v systemctl >/dev/null 2>&1; then
    fatal "systemd/systemctl is required by this installer."
  fi

  case "$OS_ID" in
    debian)
      case "$OS_VERSION_MAJOR" in
        11|12|13) ;;
        *) warn "Debian $OS_VERSION_ID is not in the installer's reviewed version list. Repository availability will still be checked before installation." ;;
      esac
      ;;
    ubuntu)
      case "$OS_VERSION_ID" in
        22.04|24.04|25.10|26.04) ;;
        *) warn "Ubuntu $OS_VERSION_ID is not in the installer's reviewed version list. Repository availability will still be checked before installation." ;;
      esac
      ;;
    rhel)
      case "$OS_VERSION_MAJOR" in
        8|9|10) ;;
        *) warn "RHEL $OS_VERSION_ID is not in the installer's reviewed version list. Repository availability will still be checked before installation." ;;
      esac
      ;;
    centos)
      case "$OS_VERSION_MAJOR" in
        9|10) ;;
        *) warn "CentOS $OS_VERSION_ID is not in the installer's reviewed version list. Repository availability will still be checked before installation." ;;
      esac
      ;;
    fedora)
      case "$OS_VERSION_MAJOR" in
        43|44) ;;
        *) warn "Fedora $OS_VERSION_ID is not in the installer's reviewed version list. Repository availability will still be checked before installation." ;;
      esac
      ;;
  esac
}

show_system_summary() {
  local effective_user login_user existing_docker

  effective_user=$(id -un)
  login_user=${SUDO_USER:-$effective_user}
  existing_docker="No"

  if command -v docker >/dev/null 2>&1; then
    existing_docker="Yes: $(docker --version 2>/dev/null || printf '%s' 'version unavailable')"
    INSTALL_MODE="upgrade-or-repair"
  fi

  printf '\n'
  print_divider
  printf ' Secure Docker Engine installation\n'
  print_divider
  printf ' Installer version : %s\n' "$SCRIPT_VERSION"
  printf ' Hostname          : %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf ' Operating system  : %s\n' "$OS_NAME"
  printf ' OS ID/version     : %s / %s\n' "$OS_ID" "$OS_VERSION_ID"
  printf ' Release codename  : %s\n' "${OS_CODENAME:-not applicable}"
  printf ' CPU architecture  : %s\n' "$TARGET_ARCH"
  printf ' Kernel            : %s\n' "$(uname -r)"
  printf ' Package family    : %s\n' "$OS_FAMILY"
  printf ' Docker repository : %s\n' "$DOCKER_REPO_BASE"
  printf ' Existing Docker   : %s\n' "$existing_docker"
  printf ' Effective user    : %s\n' "$effective_user"
  printf ' Login user        : %s\n' "$login_user"
  print_divider
  printf '\n'

  warn "Review the detected operating system, version, architecture, and Docker repository."
  warn "The script will stop if repository or signing-key verification fails."

  confirm_exact \
    "Docker Engine, containerd, Buildx, and Docker Compose will be installed or upgraded using the repository shown above." \
    "INSTALL"
}

secure_curl() {
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 20 \
    --retry 3 \
    --retry-delay 2 \
    "$@"
}

ensure_backup_directory() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    "${SUDO[@]}" install -d -m 0700 "$BACKUP_DIR"
  fi
}

backup_file() {
  local source_file=$1
  local destination

  [[ -e "$source_file" ]] || return 0

  ensure_backup_directory
  destination="$BACKUP_DIR$source_file"
  "${SUDO[@]}" install -d -m 0700 "$(dirname "$destination")"
  "${SUDO[@]}" cp -a -- "$source_file" "$destination"
}

remove_old_apt_docker_sources() {
  local source_file temp_file mode
  local -a source_files=()

  [[ "$OS_FAMILY" == "apt" ]] || return 0

  while IFS= read -r source_file; do
    [[ -n "$source_file" ]] && source_files+=("$source_file")
  done < <(
    grep -IlR 'download\.docker\.com' /etc/apt/sources.list.d 2>/dev/null || true
  )

  if [[ -f /etc/apt/sources.list ]] && grep -Iq 'download\.docker\.com' /etc/apt/sources.list; then
    source_files+=(/etc/apt/sources.list)
  fi

  if ((${#source_files[@]} == 0)); then
    return 0
  fi

  warn "Existing Docker APT repository entries were found and will be backed up before replacement:"
  printf '  %s\n' "${source_files[@]}"

  for source_file in "${source_files[@]}"; do
    backup_file "$source_file"
    temp_file="$TMP_DIR/$(basename "$source_file").cleaned.$RANDOM"
    mode=$(stat -c '%a' "$source_file" 2>/dev/null || printf '%s' '644')

    if [[ "$source_file" == *.sources ]]; then
      awk 'BEGIN { RS=""; ORS="\n\n" } $0 !~ /download\.docker\.com/' \
        "$source_file" > "$temp_file"
    else
      grep -v 'download\.docker\.com' "$source_file" > "$temp_file" || true
    fi

    if grep -Eq '[^[:space:]]' "$temp_file"; then
      "${SUDO[@]}" install -m "$mode" "$temp_file" "$source_file"
    else
      "${SUDO[@]}" rm -f -- "$source_file"
    fi
  done

  info "Previous Docker APT source entries were backed up under $BACKUP_DIR"
}

backup_existing_key_files() {
  local key_file

  for key_file in /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg; do
    if [[ -e "$key_file" ]]; then
      backup_file "$key_file"
    fi
  done
}

verify_gpg_fingerprint() {
  local key_file=$1
  local expected_fingerprint=$2
  local found_fingerprints

  found_fingerprints=$(
    gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null \
      | awk -F: '$1 == "fpr" {print toupper($10)}'
  )

  [[ -n "$found_fingerprints" ]] || fatal "No GPG fingerprint could be read from $key_file"

  if ! grep -Fxq "$expected_fingerprint" <<< "$found_fingerprints"; then
    printf '[ERROR] Expected Docker key fingerprint: %s\n' "$expected_fingerprint" >&2
    printf '[ERROR] Downloaded key fingerprint(s):\n%s\n' "$found_fingerprints" >&2
    fatal "Docker signing-key verification failed. The repository was not trusted."
  fi

  info "Verified Docker signing-key fingerprint: $expected_fingerprint"
}

apt_package_is_installed() {
  dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

remove_apt_conflicts() {
  local package
  local -a candidates=(
    docker.io
    docker-compose
    docker-compose-v2
    docker-doc
    podman-docker
    containerd
    runc
  )
  local -a installed=()

  if apt_package_is_installed docker-ce; then
    info "An official Docker CE package is already installed; treating this as an upgrade or repair."
    return 0
  fi

  for package in "${candidates[@]}"; do
    if apt_package_is_installed "$package"; then
      installed+=("$package")
    fi
  done

  if ((${#installed[@]} == 0)); then
    return 0
  fi

  warn "Conflicting distribution packages are installed: ${installed[*]}"
  confirm_exact \
    "These packages must be removed before Docker CE is installed. Existing data under /var/lib/docker is not deleted." \
    "REMOVE"

  DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get remove -y "${installed[@]}"
}

install_apt_family() {
  local key_temp release_url apt_arch candidate

  remove_old_apt_docker_sources

  info "Refreshing the operating-system package index..."
  "${SUDO[@]}" apt-get update

  info "Installing required security and repository tools..."
  DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y \
    --no-install-recommends \
    ca-certificates \
    curl \
    gnupg

  require_command curl
  require_command gpg
  require_command dpkg
  require_command apt-cache

  apt_arch=$(dpkg --print-architecture)
  release_url="$DOCKER_REPO_BASE/dists/$OS_CODENAME/Release"
  key_temp="$TMP_DIR/docker.asc"

  info "Verifying that Docker publishes a repository for '$OS_CODENAME'..."
  secure_curl --output "$TMP_DIR/docker-release" "$release_url"

  if ! grep -Eq '^Suite:|^Codename:' "$TMP_DIR/docker-release"; then
    fatal "The Docker repository Release file for '$OS_CODENAME' is invalid or unexpected."
  fi

  info "Downloading Docker's APT signing key over HTTPS..."
  secure_curl --output "$key_temp" "$DOCKER_REPO_BASE/gpg"
  chmod 0600 "$key_temp"
  verify_gpg_fingerprint "$key_temp" "$EXPECTED_APT_KEY_FINGERPRINT"

  remove_apt_conflicts
  backup_existing_key_files

  "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  "${SUDO[@]}" install -m 0644 "$key_temp" /etc/apt/keyrings/docker.asc

  "${SUDO[@]}" tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: $DOCKER_REPO_BASE
Suites: $OS_CODENAME
Components: stable
Architectures: $apt_arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  "${SUDO[@]}" chmod 0644 /etc/apt/sources.list.d/docker.sources

  info "Refreshing APT metadata with Docker signature verification enabled..."
  "${SUDO[@]}" apt-get update

  candidate=$(apt-cache policy docker-ce | awk '/Candidate:/ {print $2}')
  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    fatal "docker-ce has no installable candidate for $OS_NAME on architecture $apt_arch."
  fi

  info "Docker CE candidate version: $candidate"
  confirm_exact \
    "The verified Docker packages are ready to be installed from $DOCKER_REPO_BASE." \
    "PROCEED"

  DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y \
    --no-install-recommends \
    "${DOCKER_PACKAGES[@]}"
}

rpm_package_is_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

remove_rpm_conflicts() {
  local package
  local -a candidates=(
    docker
    docker-client
    docker-client-latest
    docker-common
    docker-latest
    docker-latest-logrotate
    docker-logrotate
    docker-selinux
    docker-engine-selinux
    docker-engine
    podman
    runc
  )
  local -a installed=()

  if rpm_package_is_installed docker-ce; then
    info "An official Docker CE package is already installed; treating this as an upgrade or repair."
    return 0
  fi

  for package in "${candidates[@]}"; do
    if rpm_package_is_installed "$package"; then
      installed+=("$package")
    fi
  done

  if ((${#installed[@]} == 0)); then
    return 0
  fi

  warn "Conflicting RPM packages are installed: ${installed[*]}"
  confirm_exact \
    "These packages must be removed before Docker CE is installed. Existing data under /var/lib/docker is not deleted." \
    "REMOVE"

  "${SUDO[@]}" dnf remove -y "${installed[@]}"
}

backup_existing_rpm_repo() {
  if [[ -e /etc/yum.repos.d/docker-ce.repo ]]; then
    backup_file /etc/yum.repos.d/docker-ce.repo
  fi
}

install_rpm_family() {
  local key_temp repo_temp repo_url

  require_command dnf

  info "Installing required security and repository tools..."
  "${SUDO[@]}" dnf install -y ca-certificates curl gnupg2

  require_command curl
  require_command gpg
  require_command rpm

  key_temp="$TMP_DIR/docker.gpg"
  repo_temp="$TMP_DIR/docker-ce.repo"
  repo_url="$DOCKER_REPO_BASE/docker-ce.repo"

  info "Downloading Docker's RPM signing key over HTTPS..."
  secure_curl --output "$key_temp" "$DOCKER_REPO_BASE/gpg"
  chmod 0600 "$key_temp"
  verify_gpg_fingerprint "$key_temp" "$EXPECTED_RPM_KEY_FINGERPRINT"

  info "Downloading Docker's RPM repository definition over HTTPS..."
  secure_curl --output "$repo_temp" "$repo_url"
  chmod 0600 "$repo_temp"

  grep -Eq '^[[:space:]]*gpgcheck=1[[:space:]]*$' "$repo_temp" \
    || fatal "The downloaded repository does not enforce RPM package signature checking."

  grep -Fq "$DOCKER_REPO_BASE" "$repo_temp" \
    || fatal "The downloaded repository does not point to the expected Docker repository."

  if grep -Eq '(^|[^s])http://' "$repo_temp"; then
    fatal "The downloaded Docker repository definition contains an insecure HTTP URL."
  fi

  remove_rpm_conflicts
  backup_existing_rpm_repo

  "${SUDO[@]}" rpm --import "$key_temp"
  "${SUDO[@]}" install -m 0644 "$repo_temp" /etc/yum.repos.d/docker-ce.repo

  info "Refreshing DNF metadata..."
  "${SUDO[@]}" dnf makecache --refresh

  if ! "${SUDO[@]}" dnf -q list --available docker-ce >/dev/null 2>&1 \
    && ! rpm_package_is_installed docker-ce; then
    fatal "docker-ce is unavailable for $OS_NAME on architecture $TARGET_ARCH."
  fi

  confirm_exact \
    "The verified Docker packages are ready to be installed from $DOCKER_REPO_BASE." \
    "PROCEED"

  "${SUDO[@]}" dnf install -y "${DOCKER_PACKAGES[@]}"
}

start_and_verify_docker() {
  require_command systemctl
  require_command docker

  info "Enabling and starting Docker..."
  "${SUDO[@]}" systemctl enable --now docker

  if ! "${SUDO[@]}" systemctl is-active --quiet docker; then
    "${SUDO[@]}" systemctl --no-pager --full status docker || true
    fatal "Docker was installed, but the service is not active."
  fi

  info "Docker service is active."
  "${SUDO[@]}" docker version --format 'Docker Engine server: {{.Server.Version}}'
  "${SUDO[@]}" docker compose version
  "${SUDO[@]}" docker buildx version

  if command -v ss >/dev/null 2>&1; then
    if "${SUDO[@]}" ss -lntp 2>/dev/null | grep -Eq 'dockerd.*:(2375|2376)([[:space:]]|$)'; then
      warn "Docker appears to be listening on TCP port 2375 or 2376. Review Docker daemon security immediately."
    else
      info "No Docker daemon TCP listener was detected on ports 2375 or 2376."
    fi
  else
    warn "The 'ss' command is unavailable, so Docker TCP listener verification was skipped."
  fi

  if [[ -r /etc/docker/daemon.json ]]; then
    if grep -Eq '"hosts"[[:space:]]*:' /etc/docker/daemon.json; then
      warn "/etc/docker/daemon.json contains a custom 'hosts' setting. Verify that the Docker API is not exposed insecurely."
    fi
    if grep -Eq '"insecure-registries"[[:space:]]*:' /etc/docker/daemon.json; then
      warn "/etc/docker/daemon.json contains insecure registries. Review whether they are still required."
    fi
  fi

  if ask_yes_no "Run Docker's hello-world verification container now? [Y/n]:" "Y"; then
    "${SUDO[@]}" docker run --rm hello-world
  else
    warn "The hello-world test was skipped by user choice."
  fi
}

configure_docker_group() {
  local default_user target_user

  default_user=${SUDO_USER:-$(id -un)}

  printf '\n'
  warn "Membership in the docker group grants root-equivalent control of this server."

  if ! ask_yes_no "Add a trusted user to the docker group? [y/N]:" "N"; then
    info "No user was added to the docker group. Use sudo for Docker administration."
    return 0
  fi

  printf 'Linux username [%s]: ' "$default_user"
  IFS= read -r target_user
  target_user=${target_user:-$default_user}

  id "$target_user" >/dev/null 2>&1 || fatal "The Linux user does not exist: $target_user"
  [[ "$target_user" != "root" ]] || fatal "Adding root to the docker group is unnecessary and was refused."

  "${SUDO[@]}" usermod -aG docker "$target_user"
  info "Added '$target_user' to the docker group. Log out and reconnect before using Docker without sudo."
}

print_final_report() {
  printf '\n'
  print_divider
  printf ' Docker installation completed successfully\n'
  print_divider
  printf ' Operating system : %s\n' "$OS_NAME"
  printf ' Repository       : %s\n' "$DOCKER_REPO_BASE"
  printf ' Installation mode: %s\n' "$INSTALL_MODE"

  if [[ -d "$BACKUP_DIR" ]]; then
    printf ' Backup directory : %s\n' "$BACKUP_DIR"
  else
    printf ' Backup directory : No previous Docker repository files required backup\n'
  fi

  printf '\nService status:\n'
  "${SUDO[@]}" systemctl --no-pager --full status docker | sed -n '1,12p' || true

  printf '\nSecurity reminders:\n'
  printf '  - Do not expose the Docker daemon over TCP without mutual TLS.\n'
  printf '  - Restrict GCP firewall rules before publishing container ports.\n'
  printf '  - Docker-published ports can bypass some host firewall rules.\n'
  printf '  - Keep AppArmor or SELinux enabled where supported.\n'
  printf '  - Treat docker-group membership as root-level access.\n'
  print_divider
}

main() {
  [[ -t 0 ]] || fatal "This installer requires an interactive terminal."

  setup_privileges
  prepare_workspace
  load_os_information
  check_basic_compatibility
  show_system_summary

  case "$OS_FAMILY" in
    apt) install_apt_family ;;
    rpm) install_rpm_family ;;
    *) fatal "Internal error: unknown package family '$OS_FAMILY'." ;;
  esac

  start_and_verify_docker
  configure_docker_group
  print_final_report
}

main "$@"
