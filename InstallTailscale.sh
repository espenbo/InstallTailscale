#!/bin/bash
#
# InstallTailscale.sh - install or update Tailscale from pkgs.tailscale.com
#
# Supported paths:
#   amd64            -> official per-distro install script (apt/yum/zypper/...)
#   arm / arm64 / 386 -> static binaries + init.d service (for distros without
#                        a package manager entry, e.g. embedded/WAGO targets)

set -u

URL="https://pkgs.tailscale.com/stable/"
APP_MAIN_NAME=tailscale
APP_MAIN_NAME_DEMON=tailscaled
LOGFILE="output.txt"
OS1="platform"
OS_type="Arch"
OS_ID="__"
OS_NAME="__"
VERSION_ID="__"
VERSION_CODENAME="__"
# Needs room for: the downloaded tarball (~35MB) + the extracted binaries
# (~65MB) + a backup copy of each currently-installed binary (~65MB), all on
# the same extraction filesystem. 200MB gives comfortable headroom.
MIN_REQUIRED_SPACE_MB=200
EXTRACTION_DIR=""
DATA=""
STATE_DIR="/var/lib/tailscale"
STATE_FILE="${STATE_DIR}/tailscaled.state"
INIT_SCRIPT="/etc/init.d/tailscale"

echo "" > "$LOGFILE"

# Color variables
green='\e[32m'
red="\e[31m"
clear='\e[0m'
yellow='\e[33m'

function prettyBox () {
  case $1 in
    CURRENT) color=$yellow ;;
    COMPLETE) color=$green ;;
    FAILED) color=$red ;;
    *) color=$clear ;;
  esac
  echo -e "[ ${color}${1}${clear}  ] ${2}" >&2
}

function requireRoot () {
  if [[ "$(id -u)" -ne 0 ]]; then
    prettyBox FAILED "This script must be run as root."
    exit 1
  fi
}

# Function to check if the system uses systemd
function uses_systemd () {
  [[ $(ps --no-headers -o comm 1 2>/dev/null) == "systemd" ]]
}

function getInstalledVersion () {
  if command -v "$APP_MAIN_NAME" >/dev/null 2>&1; then
    "$APP_MAIN_NAME" version 2>/dev/null | head -n1
  fi
}

function detectplatform () {
  OS1="$(uname | tr '[:upper:]' '[:lower:]')"
  if ! [[ $OS1 == "linux" || $OS1 == "darwin" ]]; then
    prettyBox FAILED "OS not supported"
    exit 2
  fi
}

function detectarchitecture () {
  local raw
  raw="$(uname -m)"
  case "$raw" in
    x86_64|amd64)
      OS_type='amd64'
      ;;
    i?86|x86)
      OS_type='386'
      ;;
    aarch64|arm64)
      OS_type='arm64'
      ;;
    armv6l|armv7l|armv6|arm)
      OS_type='arm'
      ;;
    *)
      prettyBox FAILED "CPU architecture ${raw} not supported"
      exit 2
      ;;
  esac
}

function loadOsRelease () {
  if [[ -r /etc/os-release ]]; then
    OS_ID=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
    OS_NAME=$(awk -F= '/^PRETTY_NAME=/{print $2}' /etc/os-release | tr -d '"')
    VERSION_ID=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
    VERSION_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release | tr -d '"')
  fi
  [[ -z "$VERSION_CODENAME" ]] && VERSION_CODENAME="N/A"
}

function showInstallSummary () {
  local installed_version
  installed_version="$(getInstalledVersion)"
  echo -e "------------------------------------------------"
  echo -e "| Install Summary"
  echo -e "------------------------------------------------"
  echo -e "| Target Operating System:       ${green}${OS1}${clear}"
  echo -e "| Distribution Name:             ${green}${OS_NAME}${clear}"
  echo -e "| Distribution ID:                ${green}${OS_ID}${clear}"
  echo -e "| Distribution Version ID:       ${green}${VERSION_ID}${clear}"
  echo -e "| Distribution Version Codename: ${green}${VERSION_CODENAME}${clear}"
  echo -e "| Target Arch:                   ${green}${OS_type}${clear}"
  echo -e "| Currently installed version:   ${green}${installed_version:-not installed}${clear}"
  echo -e "| URL:                           ${URL}${clear}"
  echo -e "------------------------------------------------"
}

# --- Static-binary download helpers -----------------------------------

# Fetches the stable package index once and caches it in $DATA.
function fetchStablePage () {
  if [[ -n "$DATA" ]]; then
    return 0
  fi
  DATA=$(curl -fsS "$URL") || {
    prettyBox FAILED "Could not fetch ${URL}"
    return 1
  }
}

# Looks up the static tarball filename for a given arch label (386/amd64/arm/arm64/...)
# by matching the "<li>arch: <a href="...">" line on the stable static-binaries page.
function findStaticBinaryFilename () {
  local arch_label="$1"
  fetchStablePage || return 1
  echo "$DATA" | sed -n "s#.*<li>${arch_label}: <a href=\"\([^\"]*\)\">.*#\1#p" | head -n1
}

# Extracts the version embedded in a tailscale_<version>_<arch>.tgz filename.
function versionFromFilename () {
  local filename="$1"
  local arch_label="$2"
  echo "$filename" | sed -n "s/^tailscale_\(.*\)_${arch_label}\.tgz\$/\1/p"
}

# Find a mount point with enough free space for extraction
function find_available_mountpoint () {
  local min_space_kb=$((MIN_REQUIRED_SPACE_MB * 1024))
  local best_point=""
  local best_space_kb=0

  while read -r line; do
    local mount avail
    mount=$(awk '{print $NF}' <<< "$line")
    avail=$(awk '{print $(NF-2)}' <<< "$line")
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail >= min_space_kb )) && (( avail > best_space_kb )); then
      best_space_kb=$avail
      best_point=$mount
    fi
  done < <(df -kP | tail -n +2)

  [[ -z "$best_point" ]] && return 1
  printf "%s\n" "$best_point"
}

# Prepare an extraction directory with enough free space.
function prepare_extraction_target () {
  local mountpoint
  if ! mountpoint=$(find_available_mountpoint); then
    prettyBox FAILED "No filesystem with enough space available"
    return 1
  fi

  EXTRACTION_DIR="$mountpoint/tailscale_extract.$$"
  rm -rf "$EXTRACTION_DIR"
  mkdir -p "$EXTRACTION_DIR"
  if [[ ! -w "$EXTRACTION_DIR" ]]; then
    prettyBox FAILED "Cannot write to $EXTRACTION_DIR"
    return 1
  fi
}

# Downloads and extracts the static tarball, validates that both binaries
# execute, and echoes the path to the extracted directory on success.
# Existing installed binaries are left untouched until installBinariesAtomic
# is called - a failure here never affects a running installation.
function downloadAndStageBinaries () {
  local full_url="$1"
  local archive_name extracted_dir archive_path

  archive_name="$(basename "$full_url")"

  if ! prepare_extraction_target; then
    prettyBox FAILED "Could not prepare a download/extraction directory"
    return 1
  fi

  archive_path="${EXTRACTION_DIR}/${archive_name}"
  prettyBox CURRENT "Downloading ${full_url}"
  if ! curl -fL -o "$archive_path" "$full_url"; then
    prettyBox FAILED "Download failed: ${full_url}"
    rm -rf "$EXTRACTION_DIR"
    return 1
  fi

  prettyBox CURRENT "Extracting ${archive_name}"
  if ! tar -xzf "$archive_path" -C "$EXTRACTION_DIR"; then
    prettyBox FAILED "Failed to extract ${archive_name}"
    rm -rf "$EXTRACTION_DIR"
    return 1
  fi

  extracted_dir="${EXTRACTION_DIR}/$(basename "$archive_name" .tgz)"
  if [[ ! -x "${extracted_dir}/tailscale" || ! -x "${extracted_dir}/tailscaled" ]]; then
    prettyBox FAILED "Downloaded archive did not contain both binaries"
    rm -rf "$EXTRACTION_DIR"
    return 1
  fi

  local downloaded_version
  downloaded_version="$("${extracted_dir}/tailscale" version 2>/dev/null | head -n1)"
  if [[ -z "$downloaded_version" ]]; then
    prettyBox FAILED "Downloaded tailscale binary did not run"
    rm -rf "$EXTRACTION_DIR"
    return 1
  fi
  prettyBox COMPLETE "Downloaded and validated Tailscale ${downloaded_version}"

  printf "%s\n" "$extracted_dir"
}

# Prints a file's size in bytes. Uses "wc -c" rather than "stat -c%s": several
# embedded BusyBox builds (confirmed on at least one WAGO PFC target) ship
# stat without format-string support, while wc -c is essentially universal.
function fileSizeBytes () {
  wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

# Decides how to install a single binary given free space on its destination
# filesystem. Prefers the fully atomic method (stage a full new copy
# alongside the old one, then rename into place - old and new coexist on
# disk right up to the atomic swap). Falls back to a reduced-safety method
# on filesystems too small for that: remove the old binary (already backed
# up elsewhere) first, then copy the new one directly - this only needs
# headroom for the size difference between old and new, not the full binary,
# which matters on tiny embedded root filesystems. Echoes "safe" or
# "lowspace" and returns 0, or prints a FAILED message and returns 1 if
# neither fits.
function chooseInstallMethod () {
  local dest_bin="$1"
  local new_size="$2"
  local target_dir avail_kb needed_safe_kb old_size delta needed_lowspace_kb

  target_dir="$(dirname "$dest_bin")"
  avail_kb=$(df -kP "$target_dir" | awk 'NR==2{print $4}')
  [[ -z "$avail_kb" ]] && avail_kb=0

  # 10% margin for filesystem block overhead, rounded up.
  needed_safe_kb=$(( (new_size * 11 / 10 / 1024) + 1 ))
  if (( avail_kb >= needed_safe_kb )); then
    echo "safe"
    return 0
  fi

  old_size=0
  [[ -f "$dest_bin" ]] && old_size=$(fileSizeBytes "$dest_bin")
  [[ -z "$old_size" ]] && old_size=0

  if (( old_size > 0 )); then
    delta=$(( new_size - old_size ))
    (( delta < 0 )) && delta=0
    needed_lowspace_kb=$(( (delta * 11 / 10 / 1024) + 1 ))
    if (( avail_kb >= needed_lowspace_kb )); then
      echo "lowspace"
      return 0
    fi
  fi

  prettyBox FAILED "Not enough free space on the filesystem holding ${target_dir} (have ${avail_kb}KB, need ~${needed_safe_kb}KB, or ~${needed_lowspace_kb:-$needed_safe_kb}KB in reduced-safety mode)"
  return 1
}

# Installs one binary at $2 from source $1, backing it up to $3 first.
# Picks the safest method that fits in available disk space; see
# chooseInstallMethod for what each method does.
function installOneBinary () {
  local extracted_bin="$1"
  local dest_bin="$2"
  local backup_bak="$3"
  local new_size method

  new_size=$(fileSizeBytes "$extracted_bin")
  if [[ -z "$new_size" ]]; then
    prettyBox FAILED "Could not determine size of ${extracted_bin}"
    return 1
  fi

  method=$(chooseInstallMethod "$dest_bin" "$new_size") || return 1

  if [[ -x "$dest_bin" ]]; then
    if ! cp -p "$dest_bin" "$backup_bak"; then
      prettyBox FAILED "Could not back up ${dest_bin}"
      rm -f "$backup_bak"
      return 1
    fi
  fi

  if [[ "$method" == "safe" ]]; then
    if ! cp "$extracted_bin" "${dest_bin}.new"; then
      prettyBox FAILED "Staging ${dest_bin}.new failed"
      rm -f "${dest_bin}.new"
      return 1
    fi
    chmod 755 "${dest_bin}.new"
    chown root:root "${dest_bin}.new"
    if ! mv "${dest_bin}.new" "$dest_bin"; then
      prettyBox FAILED "Atomic install of ${dest_bin} failed, restoring previous binary"
      [[ -f "$backup_bak" ]] && cp -p "$backup_bak" "$dest_bin"
      rm -f "${dest_bin}.new"
      return 1
    fi
  else
    prettyBox CURRENT "Not enough free space for a fully atomic install of ${dest_bin}; using reduced-safety mode (old binary removed before the new one is copied in)"
    rm -f "$dest_bin"
    if ! cp "$extracted_bin" "$dest_bin"; then
      prettyBox FAILED "Copying new ${dest_bin} failed, restoring previous binary from backup"
      [[ -f "$backup_bak" ]] && cp -p "$backup_bak" "$dest_bin"
      return 1
    fi
    chmod 755 "$dest_bin"
    chown root:root "$dest_bin"
  fi

  return 0
}

# Backs up whatever is currently installed, then replaces it with the
# validated binaries in $1 (the extracted directory), using the safest
# method that fits in available disk space per binary. On any failure the
# previous binaries are restored from backup and the function returns 1.
function installBinariesAtomic () {
  local extracted_dir="$1"
  local sbin_bin="/usr/sbin/${APP_MAIN_NAME}"
  local bin_bin="/usr/bin/${APP_MAIN_NAME_DEMON}"

  # Backups are kept on the extraction filesystem (already confirmed to have
  # plenty of room by prepare_extraction_target), not next to the live
  # binaries - the destination filesystem (e.g. a small embedded root fs)
  # may have too little free space to hold a second copy of each binary.
  local backup_dir
  backup_dir="$(dirname "$extracted_dir")/backup"
  mkdir -p "$backup_dir" || { prettyBox FAILED "Could not create ${backup_dir}"; return 1; }

  local sbin_bak="${backup_dir}/$(basename "$sbin_bin").bak"
  local bin_bak="${backup_dir}/$(basename "$bin_bin").bak"

  if ! installOneBinary "${extracted_dir}/tailscale" "$sbin_bin" "$sbin_bak"; then
    return 1
  fi

  if ! installOneBinary "${extracted_dir}/tailscaled" "$bin_bin" "$bin_bak"; then
    prettyBox FAILED "Restoring ${sbin_bin} from backup since ${bin_bin} install failed"
    [[ -f "$sbin_bak" ]] && cp -p "$sbin_bak" "$sbin_bin"
    return 1
  fi

  prettyBox COMPLETE "Installed ${sbin_bin} and ${bin_bin}"
  return 0
}

function promptRestartTailscaled () {
  prettyBox CURRENT "Do you want to restart the tailscaled service now? (y/N)"
  read -r response
  if ! [[ "$response" =~ ^[Yy]$ ]]; then
    prettyBox CURRENT "Manual restart required to load the new tailscaled binary."
    if uses_systemd; then
      echo "Run: systemctl restart tailscaled"
    else
      echo "Run: ${INIT_SCRIPT} stop && ${INIT_SCRIPT} start"
    fi
    echo "Then verify with: tailscale status"
    return
  fi

  prettyBox CURRENT "If this session is connected over Tailscale, the restart may drop it."
  prettyBox CURRENT "Run the restart detached so it survives an SSH disconnect? (y/N)"
  read -r detach_response

  local restart_cmd
  if uses_systemd; then
    restart_cmd="systemctl restart tailscaled"
  else
    # Use explicit stop+start rather than a "restart" verb: the init script
    # actually on disk may predate ours and only implement start/stop/status.
    restart_cmd="${INIT_SCRIPT} stop; sleep 2; ${INIT_SCRIPT} start"
  fi

  if [[ "$detach_response" =~ ^[Yy]$ ]]; then
    nohup bash -c "$restart_cmd" >/tmp/tailscale-restart.log 2>&1 </dev/null &
    disown
    prettyBox COMPLETE "Restart triggered in the background. Check /tmp/tailscale-restart.log and 'tailscale status' after reconnecting."
  else
    bash -c "$restart_cmd" | tee -a "$LOGFILE"
  fi
}

function writeInitdScript () {
  local had_existing=false
  if [[ -f "$INIT_SCRIPT" ]]; then
    prettyBox CURRENT "${INIT_SCRIPT} already exists. Overwrite with the current version? (y/N)"
    read -r response
    if ! [[ "$response" =~ ^[Yy]$ ]]; then
      prettyBox CURRENT "${INIT_SCRIPT} left unchanged."
      return
    fi
    had_existing=true
  fi

  prettyBox CURRENT "Creating ${INIT_SCRIPT} init script."

  local new_script="${INIT_SCRIPT}.new"
  cat > "$new_script" << '__INIT__'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          tailscale
# Required-Start:    $network $local_fs $remote_fs
# Required-Stop:     $network $local_fs $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Tailscale VPN daemon
### END INIT INFO

DAEMON="/usr/bin/tailscaled"
STATE="/var/lib/tailscale/tailscaled.state"
PIDFILE="/var/run/tailscaled.pid"

get_pid()
{
    if [ -r "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"

        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "$PID"
            return 0
        fi

        rm -f "$PIDFILE"
    fi

    PID="$(pidof tailscaled 2>/dev/null | awk '{print $1}')"

    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "$PID"
        return 0
    fi

    return 1
}

start()
{
    PID="$(get_pid)"

    if [ -n "$PID" ]; then
        echo "tailscaled is already running (PID $PID)"
        echo "$PID" > "$PIDFILE"
        return 0
    fi

    echo "Starting tailscaled..."

    mkdir -p /var/lib/tailscale
    mkdir -p /var/run

    "$DAEMON" --state="$STATE" >/dev/null 2>&1 &

    PID=$!
    echo "$PID" > "$PIDFILE"

    sleep 2

    if kill -0 "$PID" 2>/dev/null; then
        echo "tailscaled started (PID $PID)"
        return 0
    fi

    echo "ERROR: tailscaled failed to start"
    rm -f "$PIDFILE"
    return 1
}

stop()
{
    PID="$(get_pid)"

    if [ -z "$PID" ]; then
        echo "tailscaled is not running"
        rm -f "$PIDFILE"
        return 0
    fi

    echo "Stopping tailscaled (PID $PID)..."

    kill "$PID" 2>/dev/null || {
        echo "ERROR: failed to send SIGTERM to PID $PID"
        return 1
    }

    COUNT=0

    while kill -0 "$PID" 2>/dev/null; do
        COUNT=$((COUNT + 1))

        if [ "$COUNT" -ge 10 ]; then
            echo "ERROR: tailscaled did not stop after 10 seconds"
            return 1
        fi

        sleep 1
    done

    rm -f "$PIDFILE"

    echo "tailscaled stopped"
    return 0
}

status()
{
    PID="$(get_pid)"

    if [ -n "$PID" ]; then
        echo "tailscaled is running (PID $PID)"
        echo "$PID" > "$PIDFILE"
        return 0
    fi

    echo "tailscaled is not running"
    rm -f "$PIDFILE"
    return 3
}

restart()
{
    stop || return 1
    sleep 2
    start
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit $?
__INIT__

  if ! sh -n "$new_script" 2>/dev/null; then
    prettyBox FAILED "Generated init script failed syntax check, nothing changed"
    rm -f "$new_script"
    return 1
  fi

  chown root:root "$new_script"
  chmod 755 "$new_script"

  if $had_existing; then
    if ! cp -p "$INIT_SCRIPT" "${INIT_SCRIPT}.bak"; then
      prettyBox FAILED "Could not back up ${INIT_SCRIPT}, nothing changed"
      rm -f "$new_script"
      return 1
    fi
  fi

  if ! mv "$new_script" "$INIT_SCRIPT"; then
    prettyBox FAILED "Failed to install ${INIT_SCRIPT}, restoring previous version"
    if $had_existing && [[ -f "${INIT_SCRIPT}.bak" ]]; then
      mv "${INIT_SCRIPT}.bak" "$INIT_SCRIPT"
    fi
    rm -f "$new_script"
    return 1
  fi

  prettyBox COMPLETE "Installed ${INIT_SCRIPT}"

  if [[ ! -e /etc/rc.d/S99_tailscale ]]; then
    ln -s "$INIT_SCRIPT" /etc/rc.d/S99_tailscale 2>/dev/null
  fi

  if command -v update-rc.d >/dev/null; then
    update-rc.d tailscale defaults
    prettyBox COMPLETE "Tailscale init script created and enabled with update-rc.d."
  else
    prettyBox CURRENT "update-rc.d is not available. Manual enablement may be required."
  fi
}

# --- Per-architecture install paths ------------------------------------

# Handles the static-binary install/update path shared by arm, arm64 and 386.
function installStaticBinaries () {
  local arch_label="$1"
  local filename target_version current_version full_url extracted_dir

  filename="$(findStaticBinaryFilename "$arch_label")"
  if [[ -z "$filename" ]]; then
    prettyBox FAILED "No static binary found on ${URL} for arch '${arch_label}'"
    exit 1
  fi

  target_version="$(versionFromFilename "$filename" "$arch_label")"
  current_version="$(getInstalledVersion)"
  full_url="${URL}${filename}"

  echo "Installed version: ${current_version:-not installed}"
  echo "Available version:  ${target_version:-unknown} (${filename})"

  if [[ -n "$current_version" && "$current_version" == "$target_version" ]]; then
    prettyBox COMPLETE "Tailscale ${current_version} is already up to date. Nothing to do."
    return 0
  fi

  if [[ -n "$current_version" ]]; then
    prettyBox CURRENT "Update tailscale ${current_version} -> ${target_version}? (y/N)"
    read -r response
    if ! [[ "$response" =~ ^[Yy]$ ]]; then
      prettyBox CURRENT "Update aborted."
      return 0
    fi
  fi

  extracted_dir="$(downloadAndStageBinaries "$full_url")" || exit 1

  # downloadAndStageBinaries runs in a subshell (it's captured via $()), so
  # its EXTRACTION_DIR assignment never reaches this shell - derive the same
  # path from extracted_dir instead of relying on the global.
  local extraction_root
  extraction_root="$(dirname "$extracted_dir")"

  if ! installBinariesAtomic "$extracted_dir"; then
    rm -rf "$extraction_root"
    exit 1
  fi

  rm -rf "$extraction_root"

  if ! uses_systemd; then
    writeInitdScript
  fi
}

# --- amd64 / package-manager install path -------------------------------

# Extracts the <pre> install commands for a given distro id (e.g. "debian-bookworm")
# from the stable page, which lists each distro under <details id="ID">...<pre>...</pre>.
function findDistroInstallCommands () {
  local id="$1"
  fetchStablePage || return 1
  echo "$DATA" | awk -v id="$id" '
    $0 ~ ("<details id=\"" id "\"") { found=1 }
    found && /<pre>/ { inpre=1; next }
    found && /<\/pre>/ { exit }
    inpre { print }
  '
}

function Install_From_Tailscale_Script () {
  local search_key="${OS_ID}-${VERSION_ID}"
  local search_codename="${OS_ID}-${VERSION_CODENAME}"
  local section

  prettyBox CURRENT "Looking up install commands for ${search_key} / ${search_codename}"

  section="$(findDistroInstallCommands "$search_key")"
  if [[ -z "$section" ]]; then
    section="$(findDistroInstallCommands "$search_codename")"
  fi

  if [[ -z "$section" ]]; then
    prettyBox FAILED "No installation method found for ${search_key} or ${search_codename} on ${URL}"
    exit 1
  fi

  prettyBox CURRENT "Install commands:"
  echo "$section"
  echo
  read -p "Install Tailscale with the commands above? (y/N) " response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "Installing Tailscale for ${OS_ID} ${VERSION_ID:-$VERSION_CODENAME}..."
    echo "$section" | bash
  else
    echo "Install aborted."
    exit 1
  fi
}

# --- Main ----------------------------------------------------------------

requireRoot

prettyBox CURRENT "Detecting platform..."
detectplatform

prettyBox CURRENT "Detecting architecture..."
detectarchitecture

prettyBox CURRENT "Reading /etc/os-release..."
loadOsRelease

showInstallSummary 2>&1 | tee -a "$LOGFILE"

case "$OS_type" in
  arm)
    installStaticBinaries "arm" 2>&1 | tee -a "$LOGFILE"
    ;;
  arm64)
    installStaticBinaries "arm64" 2>&1 | tee -a "$LOGFILE"
    ;;
  386)
    installStaticBinaries "386" 2>&1 | tee -a "$LOGFILE"
    ;;
  amd64)
    Install_From_Tailscale_Script 2>&1 | tee -a "$LOGFILE"
    ;;
  *)
    prettyBox FAILED "CPU architecture ${OS_type} not supported"
    exit 2
    ;;
esac

if command -v "${APP_MAIN_NAME}" >/dev/null; then
  prettyBox CURRENT "Login and connect to tailscale? (y/N)"
  read -r response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    tailscale up | tee -a "$LOGFILE"
  fi
fi

promptRestartTailscaled
