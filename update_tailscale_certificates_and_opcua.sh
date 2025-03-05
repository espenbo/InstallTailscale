#!/bin/bash

# Exit on any error
set -e

# Define log file
LOG_FILE="/var/log/tailscale_cert_update.log"

# Get the DNSName for the current machine and remove the trailing dot
TAILSCALE_DNSNAME=$(tailscale status --json | grep "\"DNSName\": \"$(hostname | tr '[:upper:]' '[:lower:]')." | awk -F'"' '{print $4}' | sed 's/\.$//')

echo "Detected Tailscale DNS Name: $TAILSCALE_DNSNAME" | tee -a "$LOG_FILE"

if [ -z "$TAILSCALE_DNSNAME" ]; then
    echo "Error: Unable to determine the Tailscale DNSName. Exiting." | tee -a "$LOG_FILE"
    exit 1
fi

# Directories for Tailscale certificates
CERTS_DIR="/var/lib/tailscale/certs"
CERT_FILE="$CERTS_DIR/$TAILSCALE_DNSNAME.crt"
KEY_FILE="$CERTS_DIR/$TAILSCALE_DNSNAME.key"
PEM_FILE="$CERTS_DIR/$TAILSCALE_DNSNAME.pem"

# Directories for lighttpd
LIGHTTPD_CERT="/etc/lighttpd/https-cert.pem"
CERT_LINK_DIR="/etc/certificates"
CERT_KEY_DIR="/etc/certificates/keys"

# Directories for OPC UA
OPCUA_CERT_DIR="/home/codesys_root/.pki/own/cert"
OPCUA_KEY_DIR="/home/codesys_root/.pki/own/key"

# Ensure directories exist
mkdir -p "$CERT_LINK_DIR" "$CERT_KEY_DIR" "$OPCUA_CERT_DIR" "$OPCUA_KEY_DIR"
chmod 755 "$CERT_LINK_DIR" "$CERT_KEY_DIR" "$OPCUA_CERT_DIR" "$OPCUA_KEY_DIR"

# Check certificate expiration (if it exists)
if [ -f "$CERT_FILE" ]; then
    EXPIRATION_STATUS=$(openssl x509 -checkend $((7 * 86400)) -noout -in "$CERT_FILE" && echo "valid" || echo "expired")

    if [ "$EXPIRATION_STATUS" == "valid" ]; then
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
if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "Error: Required certificate files are missing." | tee -a "$LOG_FILE"
    exit 1
fi

# Generate the combined PEM file
echo "Creating PEM file..." | tee -a "$LOG_FILE"
cat "$CERT_FILE" "$KEY_FILE" > "$PEM_FILE"

# Ensure the PEM file exists
if [ ! -f "$PEM_FILE" ]; then
    echo "Error: PEM file was not created." | tee -a "$LOG_FILE"
    exit 1
fi

# --- Update Lighttpd Certificates ---
echo "Updating Lighttpd certificates..." | tee -a "$LOG_FILE"

# Backup and create symlink for HTTPS certificate
if [ ! -L "$LIGHTTPD_CERT" ]; then
    echo "Creating symlink for Lighttpd PEM file..." | tee -a "$LOG_FILE"
    mv "$LIGHTTPD_CERT" "${LIGHTTPD_CERT}.bak"
fi
ln -sf "$PEM_FILE" "$LIGHTTPD_CERT"

# Ensure symlinks exist for HTTPS
if [ ! -L "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt" ]; then
    ln -sf "$CERT_FILE" "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt"
    echo "Created symlink for CRT file." | tee -a "$LOG_FILE"
fi

if [ ! -L "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem" ]; then
    ln -sf "$PEM_FILE" "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem"
    echo "Created symlink for PEM file." | tee -a "$LOG_FILE"
fi

# Reload Lighttpd to apply changes
echo "Reloading Lighttpd server..." | tee -a "$LOG_FILE"
if ! /etc/init.d/lighttpd reload; then
    echo "Reload failed, restarting Lighttpd..." | tee -a "$LOG_FILE"
    /etc/init.d/lighttpd restart
fi

# --- Update OPC UA Certificates ---
echo "Updating OPC UA certificates..." | tee -a "$LOG_FILE"
cp -f "$CERT_FILE" "$OPCUA_CERT_DIR/tailscale_certificate.der"
cp -f "$KEY_FILE" "$OPCUA_KEY_DIR/tailscale_private_key.key"

# Set correct ownership and permissions for OPC UA certificates
chown root:admin "$OPCUA_CERT_DIR/tailscale_certificate.der" "$OPCUA_KEY_DIR/tailscale_private_key.key"
chmod 664 "$OPCUA_CERT_DIR/tailscale_certificate.der"  # rw-rw-r--
chmod 660 "$OPCUA_KEY_DIR/tailscale_private_key.key"  # rw-rw----

# Verify OPC UA certificate update
echo "Updated OPC UA certificate and key:" | tee -a "$LOG_FILE"
ls -l "$OPCUA_CERT_DIR/tailscale_certificate.der" | tee -a "$LOG_FILE"
ls -l "$OPCUA_KEY_DIR/tailscale_private_key.key" | tee -a "$LOG_FILE"

# Restart OPC UA server to apply changes
echo "Restarting OPC UA server..." | tee -a "$LOG_FILE"
systemctl restart codesys.service || echo "Warning: Failed to restart OPC UA server. Please check manually." | tee -a "$LOG_FILE"

echo "Certificate update completed successfully!" | tee -a "$LOG_FILE"
