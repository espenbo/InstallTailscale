# Install Tailscale
Script for automatic find rigth tailscale package to install
This script automates the installation of Tailscale, leveraging system architecture detection, and dynamic retrieval of the appropriate installation packages from Tailscale's official repository.
Features

    Automatic Installation Check: Detects if Tailscale is already installed and exits if present, to avoid reinstallation.
    Dynamic URL Fetching: Downloads the installation package based on the detected CPU architecture from Tailscale's stable URL.
    Compatibility Check: Ensures the operating system and CPU architecture are supported before attempting installation.
    Systemd Support: Checks if the system uses systemd and adjusts installation steps accordingly.
    Log Management: Outputs the installation process steps to a logfile for troubleshooting and records.

Dependencies

    curl: For fetching data from Tailscale's repository.
    tar: For extracting the downloaded archives.
    basename: Used in extracting filenames from URLs.

Usage

To run the script, navigate to the directory containing the script and run:

bash

./InstallTailscale3.sh

Script Functions
checkInstallStatus

Checks if Tailscale is already installed on the system and exits if it is.
prettyBox

Displays messages in colored text boxes according to the message type (e.g., CURRENT, COMPLETE, FAILED).
installNativePlaceBinarys

Handles the placement and permission setting of Tailscale binaries.
installNativeExtractBinarys

Extracts the Tailscale binary from the downloaded .tar.gz file.
Install_binaries_for_armv6, Install_binaries_for_arm64, Install_binaries_for_386

These functions fetch and install Tailscale for specific architectures.
Install_From_Tailscale_Script

Executes more complex installation procedures that are specific to Tailscale and system architecture.
Configuration

    URL: Modify the URL variable to change the download source. Currently set to Tailscale's stable package repository.
    LOGFILE: Defines the path to the logfile. Default is output.txt.
    OS1, OS_type, OS, VERSION_CODENAME: These are automatically determined by the script but can be manually set for testing in different environments.

System Requirements

    Linux or Darwin operating systems.
    Supported architectures include amd64, 386, arm64, and armv6.

Known Issues

    The script must be run with sufficient permissions to install software, typically as root.
    The handling of non-systemd systems is less robust and may require manual intervention.
