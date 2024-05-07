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

# function checkInstallStatus () {
#   if command -v ${APP_MAIN_NAME} >/dev/null; then
#     ALREADY_INSTALLED=true
#     prettyBox COMPLETE "Tailscale is already installed" | tee -a $LOGFILE
#     # Ask to remove the installed version of tailscale
#     echo "Do you want to remove the installed tailscale version? (y/N)"
#     read -r response
#     if [[ "$response" =~ ^[Yy]$ ]]; then
#       rm -f "/usr/sbin/${APP_MAIN_NAME}" | tee -a $LOGFILE
#       rm -f "/usr/bin/${APP_MAIN_NAME_DEMON}" | tee -a $LOGFILE
#       ALREADY_INSTALLED=false
#       prettyBox COMPLETE "${APP_FILENAME} file removed." | tee -a $LOGFILE
#     else
#       prettyBox CURRENT "${APP_FILENAME} file is not removed."
#       prettyBox CURRENT "Exiting with status 2"
#       exit 2
#     fi
#   else
#     echo -e "${green}Tailscale is not installed${clear}" | tee -a $LOGFILE
#   fi
# }

function prettyBox () {
  case $1 in
    CURRENT) color=$yellow ;;
    COMPLETE) color=$green ;;
    FAILED) color=$red ;;
    *) color=$clear ;;
  esac
  echo -e "[ ${color}${1}${clear}  ] ${2}"
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

  # Extract necessary information
  local os_name=$(awk -F= '/^PRETTY_NAME=/{print $2}' /etc/os-release | tr -d '"')
  local os_id=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
  local version_id=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
  local version_codename=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release | tr -d '"')

  # Handle missing VERSION_CODENAME
  if [[ -z "$version_codename" ]]; then
    version_codename="N/A"  # Default value if VERSION_CODENAME is missing
  fi

  echo -e "------------------------------------------------"
  echo -e "| Install Summary"
  echo -e "------------------------------------------------"
  echo -e "| Target Operating System:       ${green}${os_id}${clear}"
  echo -e "| Distribution Name:             ${green}${os_name}${clear}"
  echo -e "| Distribution Version ID:       ${green}${version_id}${clear}"
  echo -e "| Distribution Version Codename: ${green}${version_codename}${clear}"
  echo -e "| Target Arch:                   ${green}${OS_type}${clear}"
  echo -e "| URL:                           ${URL}${clear}"
  echo -e "------------------------------------------------"

}

function fetchAndParseData() {
    local url="$1"
    local search_key="$2"
    local search_codename="$3"
    
    # Fetch HTML data
    DATA=$(curl --silent --insecure "$url")

    # Try to find the installation section using version ID first
    SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"${search_key}\".*?</a>.*?</pre>" | tr -d '\0')

    # If not found, try using the version codename
    if [[ -z "$SECTION" ]]; then
        SECTION=$(echo "$DATA" | grep -Pzo "(?s)<a name=\"${search_codename}\".*?</a>.*?</pre>" | tr -d '\0')
    fi

    if [[ -z "$SECTION" ]]; then
        echo "No installation method found for ${search_key} or ${search_codename}."
        echo "Printing the first 2000 characters of DATA for troubleshooting:"
        echo "${DATA:0:2000}"
        exit 1
    else
        echo "Installation commands found:"
        echo "$SECTION" | grep 'sudo'  # Assuming all relevant commands are prefixed with 'sudo'
    fi
}

function main() {
    local os_id=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
    local version_id=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
    local version_codename=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release | tr -d '"')

    # Build search keys
    local search_key="${os_id}-${version_id}"
    local search_codename="${os_id}-${version_codename}"

    fetchAndParseData "$URL" "$search_key" "$search_codename"
}

showInstallSummary

main






