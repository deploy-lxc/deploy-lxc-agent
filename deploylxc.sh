#!/usr/bin/env bash
#
# incus/deploylxc.sh
#
# Installer / manager for Incus on VPS
# Provides:
#  - Install (auto detect distro; Debian -> apt; RHEL-family -> compile)
#  - Uninstall (full: remove packages/binaries/service/data)
#  - Update script (self-update from GitHub Releases)
#
# Usage:
#   sudo bash deploylxc.sh             # interactive menu
#   sudo bash deploylxc.sh --yes       # default install, non-interactive
#   sudo bash deploylxc.sh install     # same as --yes + install
#   sudo bash deploylxc.sh uninstall   # full uninstall (prompts unless --yes)
#   sudo bash deploylxc.sh update      # self-update the script from Releases
#
set -euo pipefail

###############################################################################
# Configuration / defaults
###############################################################################
readonly REPO_OWNER="Deploy-LXC"
readonly REPO_NAME="control-server"
readonly ASSET_NAME="deploylxc.sh"
readonly ASSET_DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${ASSET_NAME}"

LOG="/var/log/incus-install.log"
CLIENT_KEY="/root/incus-client.key"
CLIENT_CRT="/root/incus-client.crt"
BACKUP_DIR="/var/backups/incus-installer"
NONINTERACTIVE=false
DO_INIT=true
STORAGE_BACKEND=""
PROJECT_NAME=""
GIT_URL="https://github.com/lxc/incus.git"
GIT_REF="main"

# Live console logging (stream command output via tee) – default ON (user asked!)
LOG_TO_CONSOLE=true

###############################################################################
# Pretty output
###############################################################################
_supports_color() { [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors || echo 0)" -ge 8 ]; }
if _supports_color; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_GREEN="$(tput setaf 2)"
  C_CYAN="$(tput setaf 6)"
  C_YELLOW="$(tput setaf 3)"
  C_RED="$(tput setaf 1)"
  C_MAGENTA="$(tput setaf 5)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""; C_MAGENTA=""
fi

logo() {
  # Big "DeployLXC" banner + context line
  cat <<'EOF'
 ██████████                      ████                      █████       █████ █████   █████████ 
░░███░░░░███                    ░░███                     ░░███       ░░███ ░░███   ███░░░░░███
 ░███   ░░███  ██████  ████████  ░███   ██████  █████ ████ ░███        ░░███ ███   ███     ░░░ 
 ░███    ░███ ███░░███░░███░░███ ░███  ███░░███░░███ ░███  ░███         ░░█████   ░███         
 ░███    ░███░███████  ░███ ░███ ░███ ░███ ░███ ░███ ░███  ░███          ███░███  ░███         
 ░███    ███ ░███░░░   ░███ ░███ ░███ ░███ ░███ ░███ ░███  ░███      █  ███ ░░███ ░░███     ███
 ██████████  ░░██████  ░███████  █████░░██████  ░░███████  ███████████ █████ █████ ░░█████████ 
░░░░░░░░░░    ░░░░░░   ░███░░░  ░░░░░  ░░░░░░    ░░░░░███ ░░░░░░░░░░░ ░░░░░ ░░░░░   ░░░░░░░░░  
                       ░███                      ███ ░███                                      
                       █████                    ░░██████                                       
                      ░░░░░                      ░░░░░░                                        
                                                                           D E P L O Y   L X C
EOF
}

headline() {
  # $1 = title line
  printf "%s\n%s\n%s\n" \
    "${C_MAGENTA}${C_BOLD}$1${C_RESET}" \
    "${C_DIM}$(printf '%*s' "${#1}" '' | tr ' ' '=')${C_RESET}" \
    ""
}

say() { printf "%s\n" "$*"; }

###############################################################################
# Helpers
###############################################################################
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  # Always write to log file; mirror to console as a friendly line
  local line="${C_CYAN}$(timestamp)${C_RESET} - $*"
  echo "$(timestamp) - $*" >>"$LOG"
  printf "%b\n" "$line"
}

die() {
  echo "ERROR: $*" | tee -a "$LOG" >&2
  exit 1
}

# Print tail of log when any command fails
on_err() {
  local exit_code=$?
  echo
  echo "---- An error occurred (exit $exit_code). Last 60 log lines: ----" | tee -a "$LOG"
  tail -n 60 "$LOG" || true
  exit "$exit_code"
}
trap on_err ERR

confirm() {
  # usage: confirm "Message"
  if [ "$NONINTERACTIVE" = true ]; then
    return 0
  fi
  read -rp "$1 [y/N]: " ans
  case "${ans:-}" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

run() {
  # Stream to console (tee) AND log file, preserving original exit status
  log "${C_BOLD}+ $*${C_RESET}"
  if [ "$LOG_TO_CONSOLE" = true ]; then
    set -o pipefail
    "$@" 2>&1 | tee -a "$LOG"
    local cmd_status=${PIPESTATUS[0]}
    set +o pipefail || true
    if [ $cmd_status -ne 0 ]; then
      die "Command failed: $* (see $LOG)"
    fi
  else
    if ! "$@" >>"$LOG" 2>&1; then
      die "Command failed: $* (see $LOG)"
    fi
  fi
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root. Re-run with sudo."
  fi
}

ensure_log() {
  mkdir -p "$(dirname "$LOG")"
  touch "$LOG"
  chmod 600 "$LOG" || true
  mkdir -p "$BACKUP_DIR"
}

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    die "/etc/os-release not found; cannot detect OS."
  fi

  case "$OS_ID" in
    ubuntu|debian) PKG="apt" ;;
    rhel|centos|fedora|rocky|almalinux|ol|ol8|ol9|oracle)
      PKG="dnf"
      if ! command -v dnf >/dev/null 2>&1 && command -v yum >/dev/null 2>&1; then
        PKG="yum"
      fi
      ;;
    *) die "Unsupported OS: $OS_ID. This script supports Debian/Ubuntu and RHEL-family." ;;
  esac
  log "Detected OS: $OS_NAME ($OS_ID ${OS_VERSION}) using package manager: $PKG"
}

get_debian_codename() {
  local codename=""
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -sc 2>/dev/null || true)"
  fi
  if [ -z "$codename" ] && [ -n "${VERSION:-}" ]; then
    codename="$(echo "$VERSION" | sed -n 's/.*(\(.*\)).*/\1/p' | awk '{print tolower($0)}')"
  fi
  echo "${codename:-stable}"
}

###############################################################################
# Install functions
###############################################################################
install_debian_prereqs() {
  log "Installing Debian prerequisites"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update -y
  run apt-get install -y --no-install-recommends curl gnupg ca-certificates lsb-release openssl btrfs-progs
}

add_zabbly_repo_debian() {
  log "Attempting to add Zabbly Incus apt source"
  mkdir -p /etc/apt/keyrings
  if curl -fsSL "https://pkgs.zabbly.com/key.asc" -o /etc/apt/keyrings/zabbly.asc; then
    local codename arch
    codename="$(get_debian_codename)"
    arch="$(dpkg --print-architecture)"
    cat >/etc/apt/sources.list.d/zabbly-incus-stable.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${codename}
Components: main
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
    run apt-get update -y || true
    return 0
  else
    log "Failed to fetch zabbly key; skipping repo add"
    return 1
  fi
}

install_incus_debian() {
  log "Installing Incus (Debian/Ubuntu)"
  if ! apt-cache show incus >/dev/null 2>&1; then
    log "incus not in current apt sources; attempting to add Zabbly repo"
    add_zabbly_repo_debian || log "Repo add failed; attempting install anyway"
  fi
  run apt-get install -y incus incus-client || die "Failed to install incus via apt"
}

install_rhel_prereqs() {
  log "Installing RHEL/CentOS build prerequisites"
  if [ "$PKG" = "dnf" ]; then
    run dnf makecache --refresh -y || true
    run dnf install -y git gcc make pkgconfig openssl-devel systemd-devel libcap-devel libseccomp-devel btrfs-progs sqlite-devel which
    if ! command -v go >/dev/null 2>&1; then
      install_go_from_upstream
    else
      log "Go present: $(go version)"
    fi
  else
    run yum makecache -y || true
    run yum install -y git gcc make pkgconfig openssl-devel systemd-devel libcap-devel libseccomp-devel btrfs-progs sqlite-devel which
    if ! command -v go >/dev/null 2>&1; then
      install_go_from_upstream
    fi
  fi
}

install_go_from_upstream() {
  GOVER="1.21.14"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) GOARCH=amd64 ;;
  esac
  TGZ="/tmp/go${GOVER}.linux-${GOARCH}.tar.gz"
  log "Installing Go ${GOVER}"
  run curl -fsSL "https://go.dev/dl/go${GOVER}.linux-${GOARCH}.tar.gz" -o "$TGZ"
  rm -rf /usr/local/go
  run tar -C /usr/local -xzf "$TGZ"
  export PATH="/usr/local/go/bin:$PATH"
}

compile_and_install_incus() {
  WORKDIR="/usr/local/src/incus"
  log "Cloning incus source into $WORKDIR"
  rm -rf "$WORKDIR"
  run git clone "$GIT_URL" "$WORKDIR"
  cd "$WORKDIR"
  if [ -n "$GIT_REF" ]; then
    run git checkout "$GIT_REF" || log "git checkout $GIT_REF failed; continuing"
  fi

  if [ -f Makefile ]; then
    log "Running make"
    run make || die "make failed"
    if [ -f ./bin/incus ]; then
      run install -m 0755 ./bin/incus /usr/local/bin/incus
    elif [ -f ./cmd/incus/main.go ] || [ -f ./cmd/incus/incus ]; then
      log "Building cmd/incus"
      run /usr/local/go/bin/go build -o /usr/local/bin/incus ./cmd/incus || die "go build failed"
    fi
  else
    if [ -d ./cmd/incus ]; then
      run /usr/local/go/bin/go build -o /usr/local/bin/incus ./cmd/incus || die "go build failed"
    else
      run /usr/local/go/bin/go install ./... || die "go install failed"
    fi
  fi

  if [ -d "$WORKDIR"/packaging/systemd ]; then
    log "Installing provided systemd unit files"
    run cp -a "$WORKDIR"/packaging/systemd/*.service /etc/systemd/system/ || true
    run systemctl daemon-reload || true
  fi

  if ! command -v incus >/dev/null 2>&1; then
    die "incus binary not found after build/install"
  fi
  log "Installed incus at $(command -v incus)"
}

start_enable_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^incus'; then
      run systemctl enable --now incus || log "Failed to enable incus unit"
    else
      UNIT="$(systemctl list-unit-files | awk '/incus/ {print $1; exit}')"
      if [ -n "$UNIT" ]; then
        run systemctl enable --now "$UNIT" || log "Failed enabling $UNIT"
      else
        log "No incus systemd unit found; skipping enable"
      fi
    fi
  else
    log "systemctl not available; skipping service enable"
  fi

  log "Waiting for incus to respond (timeout ~60s)"
  COUNT=0
  until incus --version >/dev/null 2>&1 || [ $COUNT -ge 12 ]; do
    sleep 5
    COUNT=$((COUNT + 1))
  done
  if incus --version >/dev/null 2>&1; then
    log "Incus responsive: $(incus --version | head -n1)"
  else
    log "incus did not become responsive in time"
  fi
}

do_init() {
  if [ "$DO_INIT" = false ]; then
    log "Skipping incus init (--no-init)"
    return 0
  fi
  log "Running non-interactive incus init --auto"
  CMD_ARR=(incus init --auto)
  if [ -n "$STORAGE_BACKEND" ]; then
    CMD_ARR+=(--storage-backend="$STORAGE_BACKEND")
  fi
  if ! "${CMD_ARR[@]}" >>"$LOG" 2>&1; then
    log "incus init failed; check $LOG"
  else
    log "incus init done"
  fi

  if [ -n "$PROJECT_NAME" ]; then
    log "Creating project $PROJECT_NAME"
    run incus project create "$PROJECT_NAME" -c features.images=true -c features.profiles=false || log "project create failed/ignored"
  fi

  log "Enabling remote API on [::]:8443"
  if incus config set core.https_address "[::]:8443" >>"$LOG" 2>&1; then
    log "Remote API enabled successfully"
  else
    log "Failed to enable remote API; check $LOG"
  fi
}

generate_client_cert() {
  if [ -f "$CLIENT_KEY" ] || [ -f "$CLIENT_CRT" ]; then
    run cp -a "$CLIENT_KEY" "${CLIENT_KEY}.bak-$(date +%s)" || true
    run cp -a "$CLIENT_CRT" "${CLIENT_CRT}.bak-$(date +%s)" || true
  fi
  log "Generating client key and certificate"
  run openssl genpkey -algorithm RSA -out "$CLIENT_KEY" -pkeyopt rsa_keygen_bits:4096
  run openssl req -new -x509 -key "$CLIENT_KEY" -out "$CLIENT_CRT" -days 3650 -subj "/CN=incus-client"
  chmod 600 "$CLIENT_KEY" || true
  chmod 644 "$CLIENT_CRT" || true
  log "Wrote client cert -> $CLIENT_CRT and key -> $CLIENT_KEY"
}

add_cert_to_trust() {
  if ! command -v incus >/dev/null 2>&1; then
    log "incus CLI not available; cannot add cert to trust"
    return 1
  fi
  if incus config trust add "$CLIENT_CRT" >>"$LOG" 2>&1; then
    log "Added client cert to server trust"
    return 0
  else
    log "incus config trust add failed"
    return 1
  fi
}

find_server_ca() {
  CANDIDATES=(/var/lib/incus/server.crt /var/lib/incus/ssl/ca.crt /etc/incus/ssl/ca.crt /var/lib/lxd/ssl/ca.crt)
  for p in "${CANDIDATES[@]}"; do
    if [ -f "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

print_summary() {
  echo
  echo "================= Incus install summary ================="
  echo "Log file: $LOG"
  if command -v incus >/dev/null 2>&1; then
    echo "Incus CLI: $(command -v incus)"
    echo
    echo "Storage pools:"
    incus storage list || true
    echo
    echo "Networks:"
    incus network list || true
  else
    echo "Incus CLI not found"
  fi
  CA_PATH="$(find_server_ca || true)"
  if [ -n "${CA_PATH:-}" ]; then
    echo "Server CA: $CA_PATH"
    echo "-----BEGIN SERVER CA-----"
    sed -n '1,200p' "$CA_PATH" || true
    echo "-----END SERVER CA-----"
    echo "Server CA (base64):"
    base64 -w0 "$CA_PATH" || true
    echo
  else
    echo "Server CA not found in common locations."
  fi
  echo "========================================================"
  echo
}

###############################################################################
# Flows
###############################################################################
install_flow() {
  clear || true
  logo
  headline "Installing script • DeployLXC Incus installer"
  say "${C_DIM}We'll stream live logs here and also save them to${C_RESET} ${C_BOLD}$LOG${C_RESET}"
  echo

  ensure_root
  ensure_log
  detect_os

  if [ "$PKG" = "apt" ]; then
    install_debian_prereqs
    install_incus_debian
  else
    install_rhel_prereqs
    compile_and_install_incus
  fi

  log "STEP: entering start_enable_service"
  start_enable_service

  log "STEP: entering do_init"
  do_init

  log "STEP: entering print_summary"
  print_summary

  log "STEP: generating trust token"
  if incus config trust add --quiet >/dev/null 2>&1; then
    log "A trust token has been generated."
  else
    log "Failed to generate trust token."
  fi

  log "STEP: install_flow end"
  say "${C_GREEN}${C_BOLD}✅ Install complete.${C_RESET}"
}

uninstall_flow() {
  clear || true
  logo
  headline "Uninstalling • DeployLXC Incus installer"

  ensure_root
  ensure_log
  detect_os

  stop_disable_service
  uninstall_packages
  remove_compiled_binary
  remove_systemd_unit_files
  remove_cert_and_keys
  cleanup_repos_and_configs
  remove_data_dirs

  log "Uninstall flow completed (best-effort). Check $LOG for details."
  say "${C_GREEN}${C_BOLD}✅ Uninstall complete.${C_RESET}"
}

self_update() {
  clear || true
  logo
  headline "Updating installer • DeployLXC"

  ensure_root
  ensure_log

  TMP="/tmp/${ASSET_NAME}.download"
  BACKUP="${BACKUP_DIR}/${ASSET_NAME}.bak.$(date +%s)"

  log "Downloading latest installer from $ASSET_DOWNLOAD_URL to $TMP"
  if ! curl -fsSL "$ASSET_DOWNLOAD_URL" -o "$TMP"; then
    die "Failed to download $ASSET_DOWNLOAD_URL (curl error)"
  fi
  if [ ! -s "$TMP" ]; then
    die "Downloaded file is empty"
  fi
  FIRST_LINE="$(head -n1 "$TMP" | tr -d '\r\n')"
  if ! printf '%s\n' "$FIRST_LINE" | grep -q '^#!'; then
    die "Downloaded file does not start with a shebang; aborting (first line: $FIRST_LINE)"
  fi
  if head -n 20 "$TMP" | grep -qiE '<html|<head|not found|404'; then
    die "Downloaded file appears to be an HTML error page or contains 'Not Found'; aborting"
  fi

  mkdir -p "$BACKUP_DIR"
  if [ -f "$0" ]; then
    run cp -a "$0" "$BACKUP" || log "Failed to back up current script"
    log "Backed up current script to $BACKUP"
  fi

  log "Replacing $0 with downloaded version"
  run install -m 0755 "$TMP" "$0" || die "Failed to install updated script to $0"
  say "${C_GREEN}${C_BOLD}✅ Update complete.${C_RESET} ${C_DIM}(re-run the script)${C_RESET}"
}

###############################################################################
# Menu / CLI parsing
###############################################################################
show_menu() {
  clear || true
  logo
  headline "DeployLXC Incus installer"
  cat <<'EOF'
1) Install (recommended)
2) Uninstall (full - destructive)
3) Update script (self-update from Releases)
4) Help
5) Exit
EOF
  read -rp "Select option [1-5]: " choice
  case "${choice:-}" in
    1) install_flow ;;
    2) uninstall_flow ;;
    3) self_update ;;
    4|h|H|\?) print_usage; read -rp "Press Enter to return..." _; show_menu ;;
    5) echo "Exit"; exit 0 ;;
    *) echo "Invalid choice"; exit 2 ;;
  esac
}

print_usage() {
  cat <<EOF
Usage: sudo bash deploylxc.sh [options] [command]

Commands:
  install           Run installer (equivalent to --yes install)
  uninstall         Run full uninstall (prompts unless --yes)
  update            Self-update the script from GitHub Releases

Options:
  --yes, -y         Run non-interactively (assume yes)
  --no-init         Skip 'incus init' during install
  --backend NAME    Storage backend to pass to 'incus init'
  --project NAME    Create this Incus project after init
  --git-url URL     Custom git URL for building on RHEL/CentOS
  --git-ref REF     Git ref (branch/tag) to checkout when building
  --verbose         Stream command output to console (default)
  --quiet           Don't stream command output; only write to log file
  --help, -h        Show this help

Examples:
  sudo bash deploylxc.sh --yes --backend btrfs install
  sudo bash deploylxc.sh --no-init install
  sudo bash deploylxc.sh --project myproj install
  sudo bash deploylxc.sh --quiet install    # still writes to $LOG
Log file: $LOG
EOF
}

# Parse flags and commands
CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) NONINTERACTIVE=true; shift ;;
    --no-init) DO_INIT=false; shift ;;
    --backend) STORAGE_BACKEND="${2:-}"; shift 2 ;;
    --project) PROJECT_NAME="${2:-}"; shift 2 ;;
    --git-url) GIT_URL="${2:-}"; shift 2 ;;
    --git-ref) GIT_REF="${2:-}"; shift 2 ;;
    --verbose) LOG_TO_CONSOLE=true; shift ;;
    --quiet)   LOG_TO_CONSOLE=false; shift ;;
    install|uninstall|update) CMD="$1"; shift ;;
    --help|-h) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 2 ;;
  esac
done

# Respect DO_INIT flag for install
if [ "$DO_INIT" = false ]; then
  export DO_INIT=false
fi

# Dispatch
main_dispatch() {
  case "$CMD" in
    install)
      NONINTERACTIVE=true
      install_flow
      ;;
    uninstall)
      uninstall_flow
      ;;
    update)
      self_update
      ;;
    "")
      # TTY => show menu; otherwise default to non-interactive install
      if [ -t 0 ] && [ -t 1 ] && [ "$NONINTERACTIVE" = false ]; then
        show_menu
      else
        NONINTERACTIVE=true
        install_flow
      fi
      ;;
    *)
      print_usage
      exit 2
      ;;
  esac
}

main_dispatch
