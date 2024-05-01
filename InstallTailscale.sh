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
  if command -v tailscale >/dev/null; then
    ALREADY_INSTALLED=true
    prettyBox COMPLETE "Tailscale is already installed" | tee -a $LOGFILE
    prettyBox CURRENT "Exiting with status 2"
    exit 2
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

function installNativePlaceBinarys () {
            # Copy File /usr/sbin/tailscaled /usr/bin/tailscale
        prettyBoxCurrent "Copying ${APP_MAIN_NAME} to /usr/sbin/${APP_MAIN_NAME}.new"
        prettyBoxCurrent "Copying ${APP_MAIN_NAME_DEMON} to /usr/bin/${APP_MAIN_NAME_DEMON}.new"
        
        if cp "${APP_MAIN_NAME}" "/usr/sbin/${APP_MAIN_NAME}.new"; then
          prettyBoxComplete "Binary copied succesfully"
        else
          prettyBoxFailed "Failed to copy Binary" 1
        fi
        if cp "${APP_MAIN_NAME_DEMON}" "/usr/bin/${APP_MAIN_NAME_DEMON}.new"; then
          prettyBoxComplete "Binary copied succesfully"
        else
          prettyBoxFailed "Failed to copy Binary" 1
        fi


        # Set Binary Mode
        prettyBoxCurrent "Setting /usr/sbin/${APP_MAIN_NAME}.new to 0755"
        prettyBoxCurrent "Setting /usr/bin/${APP_MAIN_NAME_DEMON}.new to 0755"
        
        if chmod 775 "/usr/sbin/${APP_MAIN_NAME}.new"; then
          prettyBoxComplete "Binary modes set succesfully"
        else
          prettyBoxFailed "Failed to set Binary file modes" 1
        fi
        if chmod 775 "/usr/bin/${APP_MAIN_NAME_DEMON}.new"; then
          prettyBoxComplete "Binary modes set succesfully"
        else
          prettyBoxFailed "Failed to set Binary file modes" 1
        fi
        
        # Set owner and group
        prettyBoxCurrent "Setting /usr/sbin/${APP_MAIN_NAME}.new owner and group to root"
        prettyBoxCurrent "Setting /usr/bin/${APP_MAIN_NAME_DEMON}.new owner and group to root"
        if chown root:root "/usr/sbin/${APP_MAIN_NAME}.new"; then
          prettyBoxComplete "Binary owner and group set succesfully ${APP_MAIN_NAME}"
        else
          prettyBoxFailed "Failed to set Binary File owner and group ${APP_MAIN_NAME}" 1
        fi
        if chown root:root "/usr/bin/${APP_MAIN_NAME_DEMON}.new"; then
          prettyBoxComplete "Binary owner and group set succesfully ${APP_MAIN_NAME_DEMON}"
        else
          prettyBoxFailed "Failed to set Binary File owner and group ${APP_MAIN_NAME_DEMON}" 1
        fi


        # Overwrite /usr/bin/netbird
        prettyBoxCurrent "Overwriting /usr/sbin/${APP_MAIN_NAME} with /usr/sbin/${APP_MAIN_NAME}.new"
        if mv "/usr/sbin/${APP_MAIN_NAME}.new" "/usr/sbin/${APP_MAIN_NAME}"; then
          prettyBoxComplete "Binary Overwritten succesfully ${APP_MAIN_NAME}"
        else
          prettyBoxFailed "Failed to overwrite /usr/bin/${APP_MAIN_NAME}" 1
        fi
        prettyBoxCurrent "Overwriting /usr/bin/${APP_MAIN_NAME_DEMON} with /usr/bin/${APP_MAIN_NAME_DEMON}.new"
        if mv "/usr/bin/${APP_MAIN_NAME_DEMON}.new" "/usr/bin/${APP_MAIN_NAME_DEMON}"; then
          prettyBoxComplete "Binary Overwritten succesfully"
        else
          prettyBoxFailed "Failed to overwrite /usr/bin/${APP_MAIN_NAME_DEMON}" 1
        fi
}        

function installNativeExtractBinarys() {
  local APP_FILENAME=$1
  prettyBox CURRENT "Extracting ${APP_FILENAME}"
  if tar xf "${APP_FILENAME}"; then
    prettyBox COMPLETE "Extracted ${APP_FILENAME}"
  else
    prettyBox FAILED "Failed to extract ${APP_FILENAME}" 1
  fi
}

# Funksjon for å sjekke om systemet bruker systemd
uses_systemd() {
  [[ $(ps --no-headers -o comm 1) == "systemd" ]]
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
    #checkInstallStatus 2>&1 | tee -a $LOGFILE
    checkInstallStatus  # Do not pipe this to tee if it affects the exit behavior
prettyBox CURRENT "This should not be seen if Tailscale is installed already and detected."

prettyBox CURRENT "Run showInstallSummary"
showInstallSummary 2>&1 | tee -a $LOGFILE

# prettyBox CURRENT "Install_binaries"
#    Install_binaries 2>&1 | tee -a $LOGFILE

case "$OS_type" in
  armv7l|armv6)
    Install_binaries_for_armv6
    ;;
  arm64)
    Install_binaries_for_arm64
    ;;
  386)
    Install_binaries_for_386
    ;;
  amd64)
    Install_From_Tailscale_Script
    ;;
  *)
    prettyBox FAILED "CPU architecture ${OS_type} not supported"
    exit 2
    ;;
esac
