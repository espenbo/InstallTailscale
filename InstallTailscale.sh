#!/bin/bash

URL="https://pkgs.tailscale.com/stable/"
APP_MAIN_NAME=tailscale
APP_MAIN_NAME_DEMON=tailscaled
ALREADY_INSTALLED=false
LOGFILE="output.txt"
OS1="platform"
OS_type="Arch"
OS="Distro"
VERSION_CODENAME="Distro version"
SECTION="__"
DATA=""
echo "" > $LOGFILE
# Color Variables
green='\e[32m'
red="\e[31m"
clear='\e[0m'
yellow='\e[33m'

function checkInstallStatus () {
  if command -v ${APP_MAIN_NAME} >/dev/null; then
    ALREADY_INSTALLED=true
    prettyBox COMPLETE "Tailscale is already installed" | tee -a $LOGFILE
    # Ask to remove the installed version of tailscale
    echo "Do you want to remove the installed tailscale version? (y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      rm -f "/usr/sbin/${APP_MAIN_NAME}" | tee -a $LOGFILE
      rm -f "/usr/bin/${APP_MAIN_NAME_DEMON}" | tee -a $LOGFILE
      ALREADY_INSTALLED=false
      prettyBox COMPLETE "${APP_FILENAME} file removed." | tee -a $LOGFILE
    else
      prettyBox CURRENT "${APP_FILENAME} file is not removed."
      prettyBox CURRENT "Exiting with status 2"
      exit 2
    fi
  else
    echo -e "${green}Tailscale is not installed${clear}" | tee -a $LOGFILE
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

function extractFilenameFromURL() {
    local url=$1
    local filename=$(basename "$url")
    echo "$filename"
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

  # Remove any old versions of the unpacked folder to avoid conflicts
  local extracted_dir=$(basename "${APP_FILENAME}" .tgz)
  rm -rf "./${extracted_dir}" | tee -a $LOGFILE

  if tar -xzf "${APP_FILENAME}"; then
    prettyBox CURRENT "Extracted ${APP_FILENAME}"
    # Ask to remove the downloaded file
    echo "Do you want to remove the downloaded file ${APP_FILENAME}? (y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      rm -f "${APP_FILENAME}" | tee -a $LOGFILE
      prettyBox COMPLETE "${APP_FILENAME} file removed."
    else
      prettyBox COMPLETE "${APP_FILENAME} file is not removed."
    fi

    # Continue operations within the unpacked directory
    cd "${extracted_dir}"
    installNativePlaceBinarys  # Assume this function handles files within the current directory correctly
    cd ..
  else
    prettyBox FAILED "Failed to extract ${APP_FILENAME}" 1
  fi
}

function logicForinitd() {
    # Define file path and file name
    local init_script="/etc/init.d/tailscale"

    # Check if the script already exists to avoid overwriting
    if [[ -f "$init_script" ]]; then
      prettyBox FAILED "$init_script already exists." | tee -a $LOGFILE

      prettyBox CURRENT "Do you want to overwrite the $init_script file? (y/N)"
      read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
          rm -f "${$init_script}" | tee -a $LOGFILE
          prettyBox COMPLETE "${$init_script} file removed."
        else
          prettyBox COMPLETE "${$init_script} file is not removed."
        return
        fi
    fi

    # Create init-script with necessary content
    prettyBox CURRENT "Creating ${init_script} init script."
    cat > "$init_script" << 'EOF'
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
    /usr/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state
    ;;
stop)
    echo "Stopping Tailscale..."
    /usr/bin/tailscale down
    ;;
*)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
EOF

    # Set execution rights for the script
    prettyBox CURRENT "Set chown root:root and +x to the ${init_script} file."
    chown root:root "$init_script}"
    chmod +x "$init_script"

    # Register the script to run at startup
    prettyBox CURRENT "update-rc.d tailscale defaults"
    update-rc.d tailscale defaults

    prettyBox COMPLETE "Tailscale init script created and enabled."
}



# detect the platform
OS1="$(uname | tr '[:upper:]' '[:lower:]')"
if ! [[ $OS1 == "linux" || $OS1 == "darwin" ]]; then
  prettyBox FAILED "OS not supported"
  exit 2 # Exits the script if Tailscale is found
fi

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

  #FULL_URL="https://pkgs.tailscale.com/stable/$LINK"
  FULL_URL="${URL}${LINK}"
  prettyBox CURRENT "Downloading $FULL_URL"
  APP_FILENAME=$(extractFilenameFromURL "$FULL_URL")
  if uses_systemd; then
    prettyBox CURRENT "System uses systemd. Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
  else
    prettyBox CURRENT "The system does not use systemd. Creating init.d script..."
    prettyBox CURRENT "Downloading with curl..."
    curl -o "$LINK" "$FULL_URL"
    # Add logic for init.d script here
    installNativeExtractBinarys "$APP_FILENAME"
  fi
}
  
function Install_binaries_for_arm64() {
  prettyBox CURRENT "Install_binaries_for_armv64"
  prettyBox CURRENT "Fetching installation methods from Tailscale..."
  DATA=$(curl --silent --insecure "$URL")

  # Parsing the section that matches the OS type (updated to find the correct binary link)
  SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"static\".*?<ul>.*?<li>arm64: <a href=\"([^\"]+)\">.*?</ul>" | tr -d '\0' | sed -n 's/.*href="\([^"]*\).*/\1/p')

  if [ -z "$SECTION" ]; then
    prettyBox FAILED "No installation method found for arm64."
    exit 1
  fi

  if uses_systemd; then
    prettyBox CURRENT "Downloading $SECTION"
    wget "https://pkgs.tailscale.com/stable/$SECTION"
  else
    prettyBox CURRENT "The system does not use systemd. Creating init.d script..."
    # Add logic for init.d script here
    prettyBox CURRENT "Downloading $SECTION"
    wget "https://pkgs.tailscale.com/stable/$SECTION"
  fi
}

function Install_binaries_for_386() {
  prettyBox CURRENT "Install_binaries_for_386"  
  prettyBox CURRENT "Fetching installation methods from Tailscale..."
  DATA=$(curl --silent --insecure "$URL")

  # Parsing the section that matches the OS type (updated to find the correct binary link)
  SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"static\".*?<ul>.*?<li>arm64: <a href=\"([^\"]+)\">.*?</ul>" | tr -d '\0' | sed -n 's/.*href="\([^"]*\).*/\1/p')

  if [ -z "$SECTION" ]; then
    prettyBox FAILED "No installation method found for arm64."
    exit 1
  fi

  if uses_systemd; then
    prettyBox CURRENT "Downloading $SECTION"
    wget "https://pkgs.tailscale.com/stable/$SECTION"
  else
    prettyBox CURRENT "The system does not use systemd. Creating init.d script..."
    # Add logic for init.d script here
    prettyBox CURRENT "Downloading $SECTION"
    wget "https://pkgs.tailscale.com/stable/$SECTION"
  fi
}

  # Henter pakkeliste fra Tailscale for gjeldende distribusjon
function Install_From_Tailscale_Script() {
  prettyBox CURRENT "Henter installasjonsmetoder fra Tailscale..."
  DATA=$(curl --silent --insecure "$URL")

  # Søker etter seksjonen som matcher operativsystemet og versjonen
  SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"$OS-$VERSION_CODENAME\".*?$OS-$VERSION_CODENAME\">.*?</a>.*?</pre>" | tr -d '\0')


# Install from script from the tailscale page
  if [[ -z "$SECTION" ]]; then
    echo "Ingen installasjonsmetode funnet for $OS $VERSION_CODENAME"
    echo "Print ut første del av DATA for feilsøking:"
    echo "${DATA:0:2000}"  # Øker antallet tegn for å få et bedre innblikk
    exit 1
  else
    echo "Følgende kommandoer vil bli utført med sudo:"
    echo "$SECTION" | grep 'sudo'
    read -p "Ønsker du å fortsette med installasjonen? (y/N) " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      echo "Installerer Tailscale for $OS $VERSION_CODENAME..."
      echo "$SECTION" | grep 'curl' | bash
    else
      echo "Installasjon avbrutt."
      exit 1
    fi
  fi
}


prettyBox CURRENT "Checking if Tailscale is installed..."
checkInstallStatus  # Do not pipe this to tee if it affects the exit behavior
prettyBox CURRENT "This should not be seen if Tailscale is installed already and detected."

prettyBox CURRENT "Run showInstallSummary"
showInstallSummary 2>&1 | tee -a $LOGFILE

case "$OS_type" in
  armv7l|armv6)
    Install_binaries_for_armv6 2>&1 | tee -a $LOGFILE
    ;;
  arm64)
    Install_binaries_for_arm64 2>&1 | tee -a $LOGFILE
    ;;
  386)
    Install_binaries_for_386 2>&1 | tee -a $LOGFILE
    ;;
  amd64)
    Install_From_Tailscale_Script 2>&1 | tee -a $LOGFILE
    ;;
  *)
    prettyBox FAILED "CPU architecture ${OS_type} not supported"
    exit 2
    ;;
esac

