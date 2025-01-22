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
    exit 1
fi

# Directories for certificates
CERTS_DIR="/var/lib/tailscale/certs"
LIGHTTPD_CERT="/etc/lighttpd/https-cert.pem"
PEM_FILE="$CERTS_DIR/$TAILSCALE_DNSNAME.pem"

# Update Tailscale certificate
echo "Requesting new Tailscale certificate for $TAILSCALE_DNSNAME..."
tailscale cert "$TAILSCALE_DNSNAME"

# Generate the combined PEM file
echo "Combining certificate and key into PEM file..."
cat "$CERTS_DIR/$TAILSCALE_DNSNAME.crt" "$CERTS_DIR/$TAILSCALE_DNSNAME.key" > "$PEM_FILE"

# Symlink the PEM file for lighttpd
if [ ! -L "$LIGHTTPD_CERT" ]; then
    echo "Creating symlink for lighttpd PEM file..."
    mv "$LIGHTTPD_CERT" "${LIGHTTPD_CERT}.bak"  # Backup original certificate
fi
ln -sf "$PEM_FILE" "$LIGHTTPD_CERT"

# Reload lighttpd to apply the changes
echo "Reloading lighttpd server..."
/etc/init.d/lighttpd reload

echo "Certificate update completed successfully!"




