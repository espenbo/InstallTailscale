#!/bin/bash

# STATUS: EXPERIMENTAL / UNVERIFIED. The lighttpd-certificate half of this
# script uses the same logic as update_tailscale_certificates.sh, which IS
# verified working on real WAGO hardware. The OPC UA half is NOT verified to
# actually work, and available evidence suggests it likely does not:
#   - WAGO support (community.wago.com, "OPC UA Certificates" thread) states
#     the CODESYS OPC UA Server does not support GDS certificate push.
#   - A community user (community.wago.com, "Tech Note: 3S Runtime with OPC
#     UA Server", post #9) reports getting a "Bad" certificate error using
#     this exact approach (OpenSSL cert converted to DER).
#   - OPC UA requires the server certificate's SubjectAltName to include a
#     URI matching the server's ApplicationUri (per WAGO support in the
#     "PFC100 OPC UA - CA Certificate handling" thread); a Tailscale/Let's
#     Encrypt certificate only has a DNS SAN, never a URI SAN.
#   - CODESYS may also regenerate its own self-signed identity certificate
#     on runtime restart regardless of what other files exist in the PKI
#     directory (per the PFC100 thread), so simply dropping a file in there
#     may not even be picked up.
# See README.md for the full writeup. Treat this script as a documented
# starting point, not a working solution, until someone actually verifies
# an OPC UA client can connect using the resulting certificate.

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
# NOTE: /etc/lighttpd/https-cert.pem is NOT the right target - WAGO's own
# /etc/init.d/lighttpd unconditionally re-symlinks it to custom-cert.pem (if
# present) or default-cert.pem on every start/reload, clobbering anything we
# put there directly. custom-cert.pem is WAGO's actual "bring your own cert"
# hook; pointing it there survives lighttpd restarts. (Confirmed on a real
# PFC300 - see update_tailscale_certificates.sh for the same fix.)
LIGHTTPD_CERT="/etc/lighttpd/custom-cert.pem"
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
    # NOTE: "openssl ... -checkend" prints its own "Certificate will/will not
    # expire" line to stdout even with -noout (that flag only suppresses the
    # cert dump) - without redirecting it, that text ends up captured into
    # EXPIRATION_STATUS alongside our own echo, so it never equals exactly
    # "valid" and renewal fires on every run regardless of actual expiry.
    EXPIRATION_STATUS=$(openssl x509 -checkend $((7 * 86400)) -noout -in "$CERT_FILE" >/dev/null 2>&1 && echo "valid" || echo "expired")

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

# Generate the combined PEM file. Only rebuild when the source .crt/.key are
# newer than the PEM (or the PEM is missing) - also used to decide below
# whether lighttpd/OPC UA actually need to be touched at all this run.
CERT_CHANGED=false
if [ ! -f "$PEM_FILE" ] || [ "$CERT_FILE" -nt "$PEM_FILE" ] || [ "$KEY_FILE" -nt "$PEM_FILE" ]; then
    echo "Creating/updating PEM file..." | tee -a "$LOG_FILE"
    cat "$CERT_FILE" "$KEY_FILE" > "$PEM_FILE"
    CERT_CHANGED=true
else
    echo "PEM file already up to date, skipping rebuild." | tee -a "$LOG_FILE"
fi

# Ensure the PEM file exists
if [ ! -f "$PEM_FILE" ]; then
    echo "Error: PEM file was not created." | tee -a "$LOG_FILE"
    exit 1
fi

# --- Update Lighttpd Certificates ---
echo "Updating Lighttpd certificates..." | tee -a "$LOG_FILE"

# Backup and create symlink for HTTPS certificate.
# NOTE: only back up if something is actually there - custom-cert.pem won't
# exist on a device that has never had a custom cert installed before, and
# "mv" on a nonexistent source would abort the whole script under "set -e".
if [ -e "$LIGHTTPD_CERT" ] && [ ! -L "$LIGHTTPD_CERT" ]; then
    echo "Backing up existing lighttpd cert file..." | tee -a "$LOG_FILE"
    mv "$LIGHTTPD_CERT" "${LIGHTTPD_CERT}.bak"
fi
# Track whether the symlink target is actually changing, so a first-ever
# setup or a repaired/missing symlink also triggers the reload below - not
# just a rebuilt PEM.
PREV_LIGHTTPD_LINK=""
if [ -L "$LIGHTTPD_CERT" ]; then
    PREV_LIGHTTPD_LINK="$(readlink "$LIGHTTPD_CERT")"
fi
ln -sf "$PEM_FILE" "$LIGHTTPD_CERT"
if [ "$PREV_LIGHTTPD_LINK" != "$PEM_FILE" ]; then
    CERT_CHANGED=true
fi

# Ensure symlinks exist for HTTPS
if [ ! -L "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt" ]; then
    ln -sf "$CERT_FILE" "$CERT_LINK_DIR/$TAILSCALE_DNSNAME.crt"
    echo "Created symlink for CRT file." | tee -a "$LOG_FILE"
fi

if [ ! -L "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem" ]; then
    ln -sf "$PEM_FILE" "$CERT_KEY_DIR/$TAILSCALE_DNSNAME.pem"
    echo "Created symlink for PEM file." | tee -a "$LOG_FILE"
fi

# Reload Lighttpd only if the certificate actually changed this run - a
# no-op run (the common case on a 14-day cron cycle) shouldn't restart the
# web server for nothing.
if [ "$CERT_CHANGED" = true ]; then
    echo "Reloading Lighttpd server..." | tee -a "$LOG_FILE"
    if ! /etc/init.d/lighttpd reload; then
        echo "Reload failed, restarting Lighttpd..." | tee -a "$LOG_FILE"
        /etc/init.d/lighttpd restart
    fi
else
    echo "Certificate unchanged, skipping lighttpd reload." | tee -a "$LOG_FILE"
fi

# --- Update OPC UA Certificates ---
# Only touch these, and only restart the OPC UA/control runtime, when the
# certificate actually changed - restarting a live PLC control service on
# every 14-day cron run regardless of need is not acceptable.
if [ "$CERT_CHANGED" = true ]; then
    echo "Updating OPC UA certificates..." | tee -a "$LOG_FILE"

    # NOTE: "tailscale cert" writes PEM-encoded (base64 text) files.
    # Naively cp'ing $CERT_FILE to a ".der" name does NOT make it DER
    # (binary ASN.1) - it's still PEM content with a misleading extension.
    # Convert properly. The private key is also converted to DER to match
    # the existing self-generated identity files already in these
    # directories (all named *.key but DER-encoded) - verify this
    # assumption against one of those existing files before relying on it,
    # since it wasn't possible to confirm against a live OPC UA service.
    openssl x509 -in "$CERT_FILE" -outform DER -out "$OPCUA_CERT_DIR/tailscale_certificate.der"
    openssl pkey -in "$KEY_FILE" -outform DER -out "$OPCUA_KEY_DIR/tailscale_private_key.key"

    # Set correct ownership and permissions for OPC UA certificates
    chown root:admin "$OPCUA_CERT_DIR/tailscale_certificate.der" "$OPCUA_KEY_DIR/tailscale_private_key.key"
    chmod 664 "$OPCUA_CERT_DIR/tailscale_certificate.der"  # rw-rw-r--
    chmod 660 "$OPCUA_KEY_DIR/tailscale_private_key.key"  # rw-rw----

    # Verify OPC UA certificate update
    echo "Updated OPC UA certificate and key:" | tee -a "$LOG_FILE"
    ls -l "$OPCUA_CERT_DIR/tailscale_certificate.der" | tee -a "$LOG_FILE"
    ls -l "$OPCUA_KEY_DIR/tailscale_private_key.key" | tee -a "$LOG_FILE"

    # Restart the CODESYS runtime to apply changes.
    # NOTE: there is no "codesys.service" systemd unit on WAGO PTXdist
    # controllers (confirmed on a real PFC300) - the runtime is managed by
    # /etc/init.d/runtime, which only implements start/stop (no restart
    # verb), so it must be called as an explicit stop then start. This
    # genuinely stops the running PLC control program for several seconds
    # (graceful stop with a 10s timeout, then SIGKILL) - not a lightweight
    # service bounce. Confirmed on a real PFC300 that stop+start correctly
    # brings codesys3 back up with a fresh PID.
    echo "Restarting CODESYS runtime..." | tee -a "$LOG_FILE"
    /etc/init.d/runtime stop || true
    /etc/init.d/runtime start || echo "Warning: Failed to restart the CODESYS runtime. Please check manually." | tee -a "$LOG_FILE"
else
    echo "Certificate unchanged, skipping OPC UA certificate update and restart." | tee -a "$LOG_FILE"
fi

echo "Certificate update completed successfully!" | tee -a "$LOG_FILE"
