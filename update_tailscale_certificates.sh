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


# Exit on any error
set -e

# Get the DNSName for the current machine and remove the trailing dot
TAILSCALE_DNSNAME=$(tailscale status --json | grep "\"DNSName\": \"$(hostname | tr '[:upper:]' '[:lower:]')." | awk -F'"' '{print $4}' | sed 's/\.$//')

if [ -z "$TAILSCALE_DNSNAME" ]; then
    echo "Error: Unable to determine the Tailscale DNSName. Exiting."
    logger -t update_tailscale_certificates "Error: Unable to determine the Tailscale DNSName."
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

# Check certificate expiration (if it exists)
CERT_FILE="$CERTS_DIR/$TAILSCALE_DNSNAME.crt"
if [ -f "$CERT_FILE" ]; then
    EXPIRATION_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
    EXPIRATION_EPOCH=$(date -d "$EXPIRATION_DATE" +%s)
    CURRENT_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRATION_EPOCH - CURRENT_EPOCH) / 86400 ))
    
    if [ "$DAYS_LEFT" -gt 7 ]; then
        echo "Certificate is still valid for $DAYS_LEFT days, skipping renewal."
        logger -t update_tailscale_certificates "Certificate is still valid for $DAYS_LEFT days, skipping renewal."
    else
        echo "Certificate expires soon ($DAYS_LEFT days left), renewing..."
    fi
else
    echo "No existing certificate found, generating new one."
fi

# Update Tailscale certificate
echo "Requesting new Tailscale certificate for $TAILSCALE_DNSNAME..."
tailscale cert "$TAILSCALE_DNSNAME"

# Verify that certificate and key files were created
if [ ! -f "$CERTS_DIR/$TAILSCALE_DNSNAME.crt" ] || [ ! -f "$CERTS_DIR/$TAILSCALE_DNSNAME.key" ]; then
    echo "Error: Failed to generate Tailscale certificate."
    logger -t update_tailscale_certificates "Error: Failed to generate certificate for $TAILSCALE_DNSNAME."
    exit 1
fi

# Generate the combined PEM file
echo "Combining certificate and key into PEM file..."
cat "$CERTS_DIR/$TAILSCALE_DNSNAME.crt" "$CERTS_DIR/$TAILSCALE_DNSNAME.key" > "$PEM_FILE"

# Symlink the PEM file for lighttpd
if [ ! -L "$LIGHTTPD_CERT" ]; then
    echo "Creating symlink for lighttpd PEM file..."
    mv "$LIGHTTPD_CERT" "${LIGHTTPD_CERT}.bak"  # Backup original certificate
fi
ln -sf "$PEM_FILE" "$LIGHTTPD_CERT"

# Create symbolic links for other locations
ln -sf "$CERTS_DIR/$TAILSCALE_DNSNAME.crt" "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt"
ln -sf "$PEM_FILE" "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem"

# Ensure symlinks are valid
if [ ! -L "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt" ] || [ ! -L "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem" ]; then
    echo "Error: Symlink creation failed."
    logger -t update_tailscale_certificates "Error: Symlink creation failed."
    exit 1
fi

echo "Symlinks created:"
echo "  - $CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt"
echo "  - $CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem"

# Reload lighttpd to apply the changes
echo "Reloading lighttpd server..."
if ! /etc/init.d/lighttpd reload; then
    echo "Reload failed, restarting lighttpd..."
    /etc/init.d/lighttpd restart
fi

logger -t update_tailscale_certificates "Successfully updated certificate for $TAILSCALE_DNSNAME."
echo "Certificate update completed successfully!"



