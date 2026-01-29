#!/bin/bash

URL="https://pkgs.tailscale.com/stable/"
APP_MAIN_NAME=tailscale
APP_MAIN_NAME_DEMON=tailscaled
ALREADY_INSTALLED=false
LOGFILE="output.txt"
OS1="platform"
OS_type="Arch"
OS="Distro"
OS_NAME="__"
OS_ID="__"
VERSION_ID="__"
VERSION_CODENAME="Distro version"
SECTION="__"
DATA=""
MIN_REQUIRED_SPACE_MB=40
EXTRACTION_DIR=""
TMP_ARCHIVE_PATH=""

echo "" > "$LOGFILE"
# Color variables
green='\e[32m'
red="\e[31m"
clear='\e[0m'
yellow='\e[33m'

function checkInstallStatus () {
  if command -v ${APP_MAIN_NAME} >/dev/null; then
    ALREADY_INSTALLED=true
    prettyBox COMPLETE "Tailscale is already installed" | tee -a "$LOGFILE"
    # Ask to update the installed version of Tailscale
    echo "Do you want to update the installed tailscale version? (y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      rm -f "/usr/sbin/${APP_MAIN_NAME}" | tee -a "$LOGFILE"
      rm -f "/usr/bin/${APP_MAIN_NAME_DEMON}" | tee -a "$LOGFILE"
      ALREADY_INSTALLED=false
      prettyBox COMPLETE "${APP_FILENAME} file removed." | tee -a "$LOGFILE"
    else
      prettyBox CURRENT "${APP_FILENAME} file is not removed."
      prettyBox CURRENT "Exiting with status 2"
      exit 2
    fi
  else
    echo -e "${green}Tailscale is not installed${clear}" | tee -a "$LOGFILE"
  fi
}

function prettyBox () {
  case $1 in
    CURRENT) color=$yellow ;;
    COMPLETE) color=$green ;;
    FAILED) color=$red ;;
    *) color=$clear ;;
  esac
  echo -e "[ ${color}${1}${clear}  ] ${2}"
}

# Function to check if the system uses systemd
uses_systemd() {
  [[ $(ps --no-headers -o comm 1) == "systemd" ]]
}

function extractFilenameFromURL() {
    local url=$1
    local filename=$(basename "$url")
    echo "$filename"
}

# Find a mount point with enough free space for extraction
function find_available_mountpoint() {
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

# Prepare an alternate extraction directory if needed
function prepare_extraction_target() {
  local mountpoint
  if ! mountpoint=$(find_available_mountpoint); then
    prettyBox FAILED "No filesystem with enough space available"
    return 1
  fi

  EXTRACTION_DIR="$mountpoint/tailscale_extract"
  mkdir -p "$EXTRACTION_DIR"
  if [[ ! -w "$EXTRACTION_DIR" ]]; then
    prettyBox FAILED "Cannot write to $EXTRACTION_DIR"
    return 1
  fi
}

function prompt_restart_tailscaled() {
  prettyBox CURRENT "Do you want to restart the tailscaled service now? (y/N)"
  read -r response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    if uses_systemd; then
      systemctl restart tailscaled | tee -a "$LOGFILE"
    else
      if [[ -x "/etc/init.d/tailscale" ]]; then
        /etc/init.d/tailscale stop | tee -a "$LOGFILE"
        /etc/init.d/tailscale start | tee -a "$LOGFILE"
      else
        prettyBox FAILED "init.d script not found: /etc/init.d/tailscale"
        echo "Manual restart required to load the new tailscaled binary."
        echo "If you have a custom init script, restart it now."
        echo "Then verify with: tailscale status"
      fi
    fi
  else
    prettyBox CURRENT "Manual restart required to load the new tailscaled binary."
    if uses_systemd; then
      echo "Run: systemctl restart tailscaled"
      echo "If systemctl is unavailable, try: service tailscaled restart"
      echo "Then verify with: tailscale status"
    else
      echo "Run: /etc/init.d/tailscale stop"
      echo "Then: /etc/init.d/tailscale start"
      echo "If supported, you can also run: /etc/init.d/tailscale restart"
      echo "Then verify with: tailscale status"
    fi
  fi
}

function installNativePlaceBinarys() {
    # Assume this function is called from the correct directory containing the binary files
    # Move and set permissions for 'tailscale'
    if mv "tailscale" "/usr/sbin/${APP_MAIN_NAME}.new"; then
      prettyBox COMPLETE "Binary moved successfully to /usr/sbin/${APP_MAIN_NAME}.new"
      chmod 755 "/usr/sbin/${APP_MAIN_NAME}.new"
      chown root:root "/usr/sbin/${APP_MAIN_NAME}.new"
      mv "/usr/sbin/${APP_MAIN_NAME}.new" "/usr/sbin/${APP_MAIN_NAME}"
      prettyBox COMPLETE "Binary moved and set up at /usr/sbin/${APP_MAIN_NAME}"
    else
      prettyBox FAILED "Failed to move Binary to /usr/sbin/${APP_MAIN_NAME}.new" 1
    fi

    # Move and set permissions for 'tailscaled'
    if mv "tailscaled" "/usr/bin/${APP_MAIN_NAME_DEMON}.new"; then
      prettyBox COMPLETE "Binary moved successfully to /usr/bin/${APP_MAIN_NAME_DEMON}.new"
      chmod 755 "/usr/bin/${APP_MAIN_NAME_DEMON}.new"
      chown root:root "/usr/bin/${APP_MAIN_NAME_DEMON}.new"
      mv "/usr/bin/${APP_MAIN_NAME_DEMON}.new" "/usr/bin/${APP_MAIN_NAME_DEMON}"
      prettyBox COMPLETE "Binary moved and set up at /usr/bin/${APP_MAIN_NAME_DEMON}"
    else
      prettyBox FAILED "Failed to move Binary to /usr/bin/${APP_MAIN_NAME_DEMON}.new" 1
    fi
}

function installNativeExtractBinarys() {
  local APP_FILENAME=$1
  prettyBox CURRENT "Extracting ${APP_FILENAME}"

  local extracted_dir
  extracted_dir=$(basename "${APP_FILENAME}" .tgz)

  # Decide where to extract the archive
  local extraction_root="."
  if prepare_extraction_target; then
    extraction_root="$EXTRACTION_DIR"
  else
    prettyBox CURRENT "Falling back to current directory for extraction"
  fi

  # Remove any old versions of the unpacked folder to avoid conflicts
  rm -rf "${extraction_root}/${extracted_dir}" | tee -a "$LOGFILE"

  local archive_path="${APP_FILENAME}"
  if [[ "$extraction_root" != "." ]]; then
    TMP_ARCHIVE_PATH="$extraction_root/$APP_FILENAME"
    if ! mv "$APP_FILENAME" "$TMP_ARCHIVE_PATH"; then
      prettyBox FAILED "Failed to move archive to $TMP_ARCHIVE_PATH" 1
      return 1
    fi
    archive_path="$TMP_ARCHIVE_PATH"
  fi

  if tar -xzf "$archive_path" -C "$extraction_root"; then
    prettyBox CURRENT "Extracted ${APP_FILENAME}"
    # Ask to remove the downloaded file
    echo "Do you want to remove the downloaded file ${APP_FILENAME}? (y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      rm -f "$archive_path" | tee -a "$LOGFILE"
      prettyBox COMPLETE "${APP_FILENAME} file removed."
    else
      prettyBox COMPLETE "${APP_FILENAME} file is not removed."
    fi

    # Continue operations within the unpacked directory
    if [[ "$extraction_root" == "." ]]; then
      cd "${extracted_dir}"
    else
      cd "${extraction_root}/${extracted_dir}"
    fi
    installNativePlaceBinarys  # Assume this function handles files within the current directory correctly
    cd - >/dev/null

    # Clean up the temporary extraction directory if used
    if [[ -n "$EXTRACTION_DIR" && "$extraction_root" != "." ]]; then
      rm -rf "$EXTRACTION_DIR"
    fi
  else
    prettyBox FAILED "Failed to extract ${APP_FILENAME}" 1
  fi
}

function logicForinitd() {
    # Define file path and file name
    local init_script="/etc/init.d/tailscale"

    # Check if the script already exists to avoid overwriting
    if [[ -f "$init_script" ]]; then
      prettyBox FAILED "$init_script already exists." | tee -a "$LOGFILE"

      prettyBox CURRENT "Do you want to overwrite the $init_script file? (y/N)"
      read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
          rm -f "$init_script" | tee -a "$LOGFILE"
          prettyBox COMPLETE "$init_script file removed."
        else
          prettyBox COMPLETE "$init_script file is not removed."
          return
        fi
    fi

    # Create init-script with necessary content
    prettyBox CURRENT "Creating ${init_script} init script."
    cat > "$init_script" << '__INIT__'
#!/bin/sh
# Tailscale init script

### BEGIN INIT INFO
# Provides:          tailscale
# Required-Start:    $network $local_fs $remote_fs
# Required-Stop:     $network $local_fs $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Tailscale VPN
### END INIT INFO

case "$1" in
start)
    echo "Starting Tailscale..."
    /usr/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state &
    echo $! > /var/run/tailscaled.pid
    ;;
stop)
    echo "Stopping Tailscale..."
    if [ -f /var/run/tailscaled.pid ]; then
        kill `cat /var/run/tailscaled.pid`
        rm -f /var/run/tailscaled.pid
    else
        echo "Tailscale PID file not found, check if Tailscale is running."
    fi
    ;;
status)
    if [ -f /var/run/tailscaled.pid ]; then
        if ps -p `cat /var/run/tailscaled.pid` > /dev/null
        then
            echo "Tailscale is running."
        else
            echo "Tailscale PID exists but process does not. Cleaning up."
            rm -f /var/run/tailscaled.pid
            echo "Tailscale is not running."
        fi
    else
        echo "Tailscale is not running."
    fi
    ;;
*)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac

__INIT__

    # Set execution rights for the script
    prettyBox CURRENT "Set chown root:root and +x to the ${init_script} file."
    chown root:root "$init_script"
    chmod +x "$init_script"

    prettyBox CURRENT "Link the startup script to init. ln -s /etc/init.d/tailscale /etc/rc.d/S99_tailscale"
    ln -s /etc/init.d/tailscale /etc/rc.d/S99_tailscale

    # Check if update-rc.d is available and use it if it is
    if command -v update-rc.d >/dev/null; then
        update-rc.d tailscale defaults
        prettyBox COMPLETE "Tailscale init script created and enabled with update-rc.d."
    else
        prettyBox CURRENT "update-rc.d is not available. Manual setup may be required."
    fi

    prettyBox CURRENT "Start tailscale service? (y/N)"
      read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
          /etc/init.d/tailscale start | tee -a "$LOGFILE"
        fi
}


function detectplatform () {
  # Detect the platform
  OS1="$(uname | tr '[:upper:]' '[:lower:]')"
  if ! [[ $OS1 == "linux" || $OS1 == "darwin" ]]; then
    prettyBox FAILED "OS not supported"
    exit 2 # Exits the script if Tailscale is found
  fi
}

function detectarchitecture () {
  # Detect architecture
  OS_type="$(uname -m)"
  case "$OS_type" in
    x86_64|amd64)
      OS_type='amd64'
      ;;
    i?86|x86)
      OS_type='386'
      ;;
    aarch64|arm64)
      OS_type='arm64'
      ;;
    armv7l|armv6)
      OS_type='armv6'
      ;;
    *) prettyBox FAILED "OS type ${OS_type} not supported" ;;
  esac
}

# Get OS release and version
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
VERSION_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release | tr -d '"')

function showInstallSummary () {
  echo -e "------------------------------------------------"
  echo -e "| Install Summary"
  echo -e "------------------------------------------------"
  echo -e "| Target Operating System:       ${green}${OS1}${clear}"
  echo -e "| Target distribution:           ${green}${OS}${clear}"
  echo -e "| Target distribution version:   ${green}${VERSION_CODENAME}${clear}"
  echo -e "| Target Arch:                   ${green}${OS_type}${clear}"
  echo -e "| Section = OS and version:      ${SECTION}${clear}"
  echo -e "| URL:                           ${URL}${clear}"
  echo -e "------------------------------------------------"

  # Extract necessary information
  OS_NAME=$(awk -F= '/^PRETTY_NAME=/{print $2}' /etc/os-release | tr -d '"')
  OS_ID=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
  VERSION_ID=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
  VERSION_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release | tr -d '"')

  # Handle missing VERSION_CODENAME
  if [[ -z "$VERSION_CODENAME" ]]; then
    VERSION_CODENAME="N/A"  # Default value if VERSION_CODENAME is missing
  fi

  echo -e "------------------------------------------------"
  echo -e "| Install Summary"
  echo -e "------------------------------------------------"
  echo -e "| Target Operating System:       ${green}${OS_ID}${clear}"
  echo -e "| Distribution Name:             ${green}${OS_NAME}${clear}"
  echo -e "| Distribution Version ID:       ${green}${VERSION_ID}${clear}"
  echo -e "| Distribution Version Codename: ${green}${VERSION_CODENAME}${clear}"
  echo -e "| Target Arch:                   ${green}${OS_type}${clear}"
  echo -e "| URL:                           ${URL}${clear}"
  echo -e "------------------------------------------------"

}


function Install_binaries_for_armv6() {
  prettyBox CURRENT "Install_binaries_for_armv6"
  prettyBox CURRENT "Fetching installation methods from Tailscale..."
  DATA=$(curl --silent --insecure "$URL")

  # Use awk to extract the link for armv6 binaries
  LINK=$(echo "$DATA" | awk '/<li>.*tailscale_[^"]*_arm.tgz/ { print }' | sed -n 's/.*href="\([^"]*_arm\.tgz\).*/\1/p')
  prettyBox CURRENT "Found link: ${LINK}"

  if [ -z "$LINK" ]; then
    prettyBox FAILED "No installation method found for armv6."
    exit 1
  fi

  FULL_URL="${URL}${LINK}"
  prettyBox CURRENT "Downloading $FULL_URL"
  APP_FILENAME=$(extractFilenameFromURL "$FULL_URL")
  if uses_systemd; then
    prettyBox CURRENT "System uses systemd. Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
  else
    prettyBox CURRENT "Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
    prettyBox CURRENT "Extract and install native binaries"
    installNativeExtractBinarys "$APP_FILENAME"
    prettyBox CURRENT "The system does not use systemd. Creating init.d script..."
    logicForinitd
  fi
}

function Install_binaries_for_arm64() {
  prettyBox CURRENT "Install_binaries_for_armv64"
  prettyBox CURRENT "Fetching installation methods from Tailscale..."
  DATA=$(curl --silent --insecure "$URL")

  # Parsing the section that matches the OS type (updated to find the correct binary link)
  SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"static\".*?<ul>.*?<li>arm64: <a href=\"([^\"]+)\">.*?</ul>" | tr -d '\0' | sed -n 's/.*href="\([^"]*\).*/\1/p')

  if [ ! -z "$SECTION" ]; then
    prettyBox CURRENT "Found direct link for ARM64 binaries: $SECTION"
    FULL_URL="https://pkgs.tailscale.com/stable/$SECTION"
  else
    prettyBox FAILED "No direct installation method found for ARM64, trying fallback..."
    # Fallback to use awk to extract the link for ARM64 binaries if the first method fails
    LINK=$(echo "$DATA" | awk '/<li>.*tailscale_[^"]*_arm64.tgz/ { print }' | sed -n 's/.*href="\([^"]*_arm64\.tgz\).*/\1/p')

    if [ -z "$LINK" ]; then
      prettyBox FAILED "No installation method found for ARM64."
      exit 1
    fi

    FULL_URL="${URL}${LINK}"
    prettyBox CURRENT "Found link via fallback method: $FULL_URL"
  fi

  # Download the file
  prettyBox CURRENT "Downloading $FULL_URL"
  APP_FILENAME=$(extractFilenameFromURL "$FULL_URL")

  if uses_systemd; then
    prettyBox CURRENT "System uses systemd. Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
  else
    prettyBox CURRENT "Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
    prettyBox CURRENT "Extract and install native binaries"
    installNativeExtractBinarys "$APP_FILENAME"
    prettyBox CURRENT "The system does not use systemd. Creating init.d script..."
    logicForinitd
  fi
}


function Install_binaries_for_386() {
  prettyBox CURRENT "Install_binaries_for_386"
  prettyBox CURRENT "Fetching installation methods from Tailscale..."
  DATA=$(curl --silent --insecure "$URL")

  # Try to find a direct link for x86 (386) binaries
  SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"static\".*?<ul>.*?<li>x86: <a href=\"([^\"]+)\">.*?</ul>" | tr -d '\0' | sed -n 's/.*href="\([^"]*\).*/\1/p')

  if [ -z "$SECTION" ]; then
    prettyBox FAILED "No direct installation method found for 386, trying fallback..."
    # Fallback to extract the link for 386 binaries if the first method fails
    LINK=$(echo "$DATA" | awk '/<li>.*tailscale_[^"]*_386.tgz/ { print }' | sed -n 's/.*href="\([^"]*_386\.tgz\).*/\1/p')

    if [ -z "$LINK" ]; then
      prettyBox FAILED "No installation method found for 386."
      exit 1
    fi

    FULL_URL="${URL}${LINK}"
    prettyBox CURRENT "Found link via fallback method: $FULL_URL"
  else
    FULL_URL="https://pkgs.tailscale.com/stable/$SECTION"
    prettyBox CURRENT "Found direct link for 386 binaries: $SECTION"
  fi

  # Download the file
  prettyBox CURRENT "Downloading $FULL_URL"
  APP_FILENAME=$(extractFilenameFromURL "$FULL_URL")

  if uses_systemd; then
    prettyBox CURRENT "System uses systemd. Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
  else
    prettyBox CURRENT "Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
    prettyBox CURRENT "Extract and install native binaries"
    installNativeExtractBinarys "$APP_FILENAME"
    prettyBox CURRENT "The system does not use systemd. Creating init.d script..."
    logicForinitd
  fi
}


function fetchAndParseData() {
    local url="$1"
    local search_key="$2"
    local search_codename="$3"

    prettyBox CURRENT "Fetch HTML data"
    # Fetch HTML data
    DATA=$(curl --silent --insecure "$url")

    prettyBox CURRENT "Try to find the installation section using version ID first"
    # Try to find the installation section using version ID first
    SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"${search_key}\".*?</a>.*?</pre>" | tr -d '\0')

    # If not found, try using the version codename
    if [[ -z "$SECTION" ]]; then
        prettyBox CURRENT "If not found, try using the version codename"
        SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"${search_codename}\".*?</a>.*?</pre>" | tr -d '\0')
    fi

    # Try different ways to find the right command


    # Try to find the installation section using version ID first
      prettyBox CURRENT "Try to find the installation section using awk and version ID first"
    if [[ -z "$SECTION" ]]; then
      SECTION=$(echo "$DATA" | awk -v pat="a name=\"$search_key\"" '$0 ~ pat, /<\/pre>/{print}')
    fi
    # If not found, try using the version codename
    if [[ -z "$SECTION" ]]; then
        prettyBox CURRENT "If not found, try using the awk and version codename"
        SECTION=$(echo "$DATA" | awk -v pat="a name=\"$search_codename\"" '$0 ~ pat, /<\/pre>/{print}')
    fi



    prettyBox CURRENT "Try to find the installation section using version ID first 2"
    # Try to find the installation section using version ID first
    if [[ -z "$SECTION" ]]; then
      SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"${search_key2}\".*?</a>.*?</pre>" | tr -d '\0')
    fi

    # If not found, try using the version codename
    if [[ -z "$SECTION" ]]; then
        prettyBox CURRENT "If not found, try using the version codename 2"
        SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"${search_codename2}\".*?</a>.*?</pre>" | tr -d '\0')
    fi


    # Try to find the installation section using version ID first
      prettyBox CURRENT "Try to find the installation section using awk and version ID first 2"
    if [[ -z "$SECTION" ]]; then
      SECTION=$(echo "$DATA" | awk -v pat="a name=\"$search_key2\"" '$0 ~ pat, /<\/pre>/{print}')
    fi
    # If not found, try using the version codename
    if [[ -z "$SECTION" ]]; then
        prettyBox CURRENT "If not found, try using the awk and version codename 2"
        SECTION=$(echo "$DATA" | awk -v pat="a name=\"$search_codename2\"" '$0 ~ pat, /<\/pre>/{print}')
    fi


      if [[ -z "$SECTION" ]]; then
        echo "No installation method found for ${search_key} or ${search_codename}."
        echo "Printing the first 2000 characters of DATA for troubleshooting:"
        echo "${DATA:0:2000}"
        echo "$DATA"
        exit 1
      else
        prettyBox CURRENT "Installation search for sudo command:"
        echo "$SECTION" | grep 'sudo'  # Assuming all relevant commands are prefixed with 'sudo'
        read -p "Install Tailscale with the commands? (y/N) " response
      if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "Installing Tailscale for $OS $VERSION_CODENAME...$os_id $version_id"
        echo "$SECTION" | grep 'curl' | bash
      else
        echo "Install aborted."
        exit 1
      fi
    fi
}


function Install_From_Tailscale_Script() {
    local OS_ID=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
    local VERSION_ID=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
    local VERSION_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release | tr -d '"')

    # Build search keys
    local search_key="${OS_ID}-${VERSION_ID}"
    local search_codename="${OS_ID}-${VERSION_CODENAME}"
    local search_key2="${OS_ID} ${VERSION_ID}"
    local search_codename2="${OS_ID} ${VERSION_CODENAME}"

    fetchAndParseData "$URL" "$search_key" "$search_codename" "$search_key2" "$search_codename2"

}


prettyBox CURRENT "Checking if Tailscale is installed..."
checkInstallStatus

prettyBox CURRENT "Detect platform..."
detectplatform

prettyBox CURRENT "Check if it's installed"
checkInstallStatus  # Do not pipe this to tee if it affects the exit behavior

prettyBox CURRENT "Detect architrcture"
detectarchitecture

prettyBox CURRENT "Run showInstallSummary"
showInstallSummary 2>&1 | tee -a "$LOGFILE"

case "$OS_type" in
  armv7l|armv6)
    Install_binaries_for_armv6 2>&1 | tee -a "$LOGFILE"
    ;;
  arm64)
    Install_binaries_for_arm64 2>&1 | tee -a "$LOGFILE"
    ;;
  386)
    Install_binaries_for_386 2>&1 | tee -a "$LOGFILE"
    ;;
  amd64)
    Install_From_Tailscale_Script 2>&1 | tee -a "$LOGFILE"
    ;;
  *)
    prettyBox FAILED "CPU architecture ${OS_type} not supported"
    exit 2
    ;;
esac


if command -v ${APP_MAIN_NAME} >/dev/null; then
  ALREADY_INSTALLED=true
else
  prettyBox CURRENT "Login and connect to tailscale? (y/N)"
  read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      tailscale up | tee -a "$LOGFILE"
    fi
fi

prompt_restart_tailscaled
