#!/bin/bash


# The script, update_tailscale_certificates.sh, automates the process of updating Tailscale-issued certificates for a Tailscale-enabled device. 
# It dynamically retrieves the correct DNS name for the device, requests a new certificate, combines the certificate and private key into a .pem file, 
# and configures the lighttpd web server to use the updated certificate. Finally, it reloads the lighttpd server to apply the changes.


# Description of the Script
# The script, update_tailscale_certificates.sh, automates the process of updating Tailscale-issued certificates for a Tailscale-enabled device. It dynamically retrieves the correct DNS name for the device, requests a new certificate, combines the certificate and private key into a .pem file, and configures the lighttpd web server to use the updated certificate. Finally, it reloads the lighttpd server to apply the changes.
# Key Features
#    Dynamic DNS Name Detection:
#        Retrieves the device's DNS name from Tailscale's JSON status output.
#        Strips any trailing periods to ensure compatibility with the tailscale cert command.
#
#    Certificate Management:
#        Requests a new certificate using Tailscale's built-in cert command.
#        Combines the .crt and .key files into a .pem file for use by lighttpd.
#
#    Web Server Integration:
#        Configures lighttpd to use the updated .pem file.
#        Reloads lighttpd to apply the new certificate without restarting the server.

# How to Set It Up
# Save the Script: Save the script to /usr/local/bin/update_tailscale_certificates.sh:
# 
# Make It Executable:
# chmod +x /usr/local/bin/update_tailscale_certificates.sh
# Test the Script: Run the script manually to verify it works as expected:
# /usr/local/bin/update_tailscale_certificates.sh
# Set Up with Cron: Open the root user's crontab for editing:
# crontab -e
# Add the following line to schedule the script to run At 05:00 on every 14th day-of-month:   https://crontab.guru/#0_5_*/14_*_*
#    0 5 */14 * * /usr/local/bin/update_tailscale_certificates.sh >> /var/log/tailscale_cert_update.log 2>&1
# Check Logs: Monitor the log file to ensure the script runs as expected:
# tail -f /var/log/tailscale_cert_update.log


#!/bin/bash

# Exit on any error
set -e

# Define log file
LOG_FILE="/var/log/tailscale_cert_update.log"

# Get the DNSName for the current machine and remove the trailing dot
TAILSCALE_DNSNAME=$(tailscale status --json | grep "\"DNSName\": \"$(hostname | tr '[:upper:]' '[:lower:]')." | awk -F'"' '{print $4}' | sed 's/\.$//')

# Log the DNS name for debugging
echo "Detected Tailscale DNS Name: $TAILSCALE_DNSNAME" | tee -a "$LOG_FILE"

if [ -z "$TAILSCALE_DNSNAME" ]; then
    echo "Error: Unable to determine the Tailscale DNSName. Exiting." | tee -a "$LOG_FILE"
    exit 1
fi

# Directories for certificates
CERTS_DIR="/var/lib/tailscale/certs"
LIGHTTPD_CERT="/etc/lighttpd/https-cert.pem"
PEM_FILE="$CERTS_DIR/$TAILSCALE_DNSNAME.pem"

CERT_LINK_DIR="/etc/certificates"
CERT_KEY_DIR="/etc/certificates/keys"

# Ensure the directories exist
mkdir -p "$CERT_LINK_DIR" "$CERT_KEY_DIR"
chmod 755 "$CERT_LINK_DIR" "$CERT_KEY_DIR"

# Check certificate expiration (if it exists)
CERT_FILE="$CERTS_DIR/$TAILSCALE_DNSNAME.crt"
if [ -f "$CERT_FILE" ]; then
    EXPIRATION_SECONDS_LEFT=$(openssl x509 -checkend $((7 * 86400)) -noout -in "$CERT_FILE" && echo "valid" || echo "expired")
    
    if [ "$EXPIRATION_SECONDS_LEFT" == "valid" ]; then
        echo "Certificate is still valid for more than 7 days, skipping renewal." | tee -a "$LOG_FILE"
    else
        echo "Certificate expires soon or is expired, renewing..." | tee -a "$LOG_FILE"
        tailscale cert "$TAILSCALE_DNSNAME"
    fi
else
    echo "No existing certificate found, generating new one." | tee -a "$LOG_FILE"
    tailscale cert "$TAILSCALE_DNSNAME"
fi

# Verify that certificate and key files exist
if [ ! -f "$CERTS_DIR/$TAILSCALE_DNSNAME.crt" ] || [ ! -f "$CERTS_DIR/$TAILSCALE_DNSNAME.key" ]; then
    echo "Error: Required certificate files are missing." | tee -a "$LOG_FILE"
    exit 1
fi

# Generate the combined PEM file
if [ ! -f "$PEM_FILE" ]; then
    echo "Creating PEM file..." | tee -a "$LOG_FILE"
    cat "$CERTS_DIR/$TAILSCALE_DNSNAME.crt" "$CERTS_DIR/$TAILSCALE_DNSNAME.key" > "$PEM_FILE"
fi

# Ensure the PEM file exists
if [ ! -f "$PEM_FILE" ]; then
    echo "Error: PEM file was not created." | tee -a "$LOG_FILE"
    exit 1
fi

# Symlink the PEM file for lighttpd
if [ ! -L "$LIGHTTPD_CERT" ]; then
    echo "Creating symlink for lighttpd PEM file..." | tee -a "$LOG_FILE"
    mv "$LIGHTTPD_CERT" "${LIGHTTPD_CERT}.bak"  # Backup original certificate
fi
ln -sf "$PEM_FILE" "$LIGHTTPD_CERT"

# Ensure symlinks exist, even if certificate wasn't renewed
if [ ! -L "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt" ]; then
    ln -sf "$CERTS_DIR/$TAILSCALE_DNSNAME.crt" "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt"
    echo "Created symlink for CRT file." | tee -a "$LOG_FILE"
fi

if [ ! -L "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem" ]; then
    ln -sf "$PEM_FILE" "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem"
    echo "Created symlink for PEM file." | tee -a "$LOG_FILE"
fi

# Verify symlinks
if [ ! -L "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt" ] || [ ! -L "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem" ]; then
    echo "Error: Symlink verification failed." | tee -a "$LOG_FILE"
    exit 1
fi

# Debugging: List created symlinks
echo "Symlinks created and verified:" | tee -a "$LOG_FILE"
ls -l "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt" | tee -a "$LOG_FILE"
ls -l "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem" | tee -a "$LOG_FILE"

# Reload lighttpd to apply the changes
echo "Reloading lighttpd server..." | tee -a "$LOG_FILE"
if ! /etc/init.d/lighttpd reload; then
    echo "Reload failed, restarting lighttpd..." | tee -a "$LOG_FILE"
    /etc/init.d/lighttpd restart
fi

echo "Certificate update completed successfully!" | tee -a "$LOG_FILE"
