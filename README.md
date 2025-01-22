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

./InstallTailscale.sh

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

# update_tailscale_certificates.sh

`update_tailscale_certificates.sh` is a script that automates the process of updating Tailscale-issued certificates for a Tailscale-enabled device. It dynamically retrieves the correct DNS name for the device, requests a new certificate, combines the certificate and private key into a `.pem` file, and configures the `lighttpd` web server to use the updated certificate. Finally, it reloads the `lighttpd` server to apply the changes.

---

### Key Features

#### 1. **Dynamic DNS Name Detection**
- Retrieves the device's DNS name from Tailscale's JSON status output.
- Strips any trailing periods to ensure compatibility with the `tailscale cert` command.

#### 2. **Certificate Management**
- Requests a new certificate using Tailscale's built-in `cert` command.
- Combines the `.crt` and `.key` files into a `.pem` file for use by `lighttpd`.

#### 3. **Web Server Integration**
- Configures `lighttpd` to use the updated `.pem` file.
- Reloads `lighttpd` to apply the new certificate without restarting the server.

---

### How to Set It Up

#### 1. **Save the Script**
Save the script to `/usr/local/bin/update_tailscale_certificates.sh`:
```bash
sudo nano /usr/local/bin/update_tailscale_certificates.sh
```
##### Add the following line to schedule the script to run At 05:00 on every 14th day-of-month:   https://crontab.guru/#0_5_*/14_*_*
```bash
    0 5 */14 * * /usr/local/bin/update_tailscale_certificates.sh >> /var/log/tailscale_cert_update.log 2>&1
```
##### Check Logs: Monitor the log file to ensure the script runs as expected:
```bash
    tail -f /var/log/tailscale_cert_update.log
```
