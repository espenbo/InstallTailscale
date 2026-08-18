# Install Tailscale.
Script for automatically finding and installing the right Tailscale package for the current system, and safely updating it later.
This script detects the platform/architecture/distro, installs Tailscale via the appropriate method for that architecture, and safely updates an existing installation when a newer version is available.

## Features

    Version-aware updates: Compares the currently installed version against the latest available version and only updates when needed; skips cleanly if already up to date.
    Two install paths: amd64 uses Tailscale's official per-distro install script (apt/yum/zypper/...), scraped live from the stable package page. arm, arm64 and 386 download Tailscale's static binaries and install them to /usr/sbin/tailscale and /usr/bin/tailscaled, with an init.d service for systems without systemd (e.g. embedded/WAGO PLC targets).
    Safe atomic upgrades: existing binaries are never deleted before the new ones are downloaded, extracted, and verified to actually run. Old binaries are backed up before being replaced, and restored automatically if anything fails partway through.
    Low-space fallback: on filesystems too small to stage the old and new binary side by side (common on small embedded root filesystems), the script falls back to removing the old binary first (after backing it up elsewhere) - this only needs headroom for the size difference between versions rather than the full binary size.
    BusyBox-compatible: avoids GNU-only flags (e.g. uses wc -c instead of stat -c%s, plain sed/awk instead of grep -P) since several embedded BusyBox builds ship reduced tool variants.
    Systemd and init.d support: checks if the system uses systemd and uses systemctl or a generated /etc/init.d/tailscale script (with PID-file repair and pidof fallback) accordingly.
    Decoupled restart: offers to restart tailscaled after install, including an optional detached restart so it survives the SSH-over-Tailscale session it may itself interrupt.
    Log Management: Outputs the installation process steps to a logfile for troubleshooting and records.

Dependencies

    curl: For fetching data and binaries from Tailscale's repository.
    tar: For extracting the downloaded archives.
    sed, awk: For parsing the Tailscale download page.
    wc, df: For portable size/free-space checks (chosen deliberately over stat -c%s, which some embedded BusyBox builds lack).
    Must be run as root - the script checks this itself and exits if not.

Usage

To run the script, navigate to the directory containing the script and run:

bash

sudo ./InstallTailscale.sh

Script Functions
requireRoot

Exits if the script is not run as root.
prettyBox

Displays messages in colored text boxes according to the message type (e.g., CURRENT, COMPLETE, FAILED).
detectplatform, detectarchitecture, loadOsRelease

Detect the OS, CPU architecture, and distro/version.
installStaticBinaries

The arm/arm64/386 install/update path: compares installed vs. available version, downloads, and installs.
downloadAndStageBinaries

Downloads and extracts the tarball, validating that both binaries actually run before anything is installed.
installBinariesAtomic, installOneBinary, chooseInstallMethod

Back up and install each binary using the safest method that fits in available disk space, with rollback on failure.
writeInitdScript

Installs or updates /etc/init.d/tailscale, with backup and rollback.
promptRestartTailscaled

Restarts tailscaled via systemctl or the init.d script, with an optional detached mode.
Install_From_Tailscale_Script

Looks up and runs Tailscale's official per-distro install commands (the amd64 path).
Configuration

    URL: Modify the URL variable to change the download source. Currently set to Tailscale's stable package repository.
    LOGFILE: Defines the path to the logfile. Default is output.txt.
    MIN_REQUIRED_SPACE_MB: Minimum free space required on a filesystem to be used for downloading/extracting/backing up binaries. Default 200MB.
    OS1, OS_type, OS_ID, OS_NAME, VERSION_ID, VERSION_CODENAME: These are automatically determined by the script but can be manually set for testing in different environments.

System Requirements

    Linux or Darwin operating systems.
    Supported architectures include amd64, 386, arm64, and arm (covers armv6l/armv7l).
    Root privileges.

Known Issues

    On filesystems too small even for the low-space fallback (i.e. not enough room for the version-to-version size difference), the update fails with a clear error rather than partially installing.
    The generated init.d script assumes a POSIX-ish /bin/sh with pidof and kill -0 support; verified on WAGO PTXdist-based BusyBox systems.

# update_tailscale_certificates.sh

`update_tailscale_certificates.sh` automates renewing and installing a Tailscale-issued HTTPS certificate for a WAGO PLC's `lighttpd` web management interface. It detects the device's Tailscale DNS name, renews the certificate only when it's actually close to expiry, and points `lighttpd` at it - restarting the web server only when something actually changed. **Verified working end-to-end on a real PFC300** (WAGO 750-8302), including confirming in a browser that the correct certificate (not WAGO's factory default) is served.

---

### Key Features

#### 1. **Dynamic DNS Name Detection**

- Retrieves the device's own DNS name from `tailscale status --json`.
- Strips the trailing period Tailscale's DNS names carry, for compatibility with `tailscale cert`.

#### 2. **Certificate Management**

- Renews via `tailscale cert` only when the certificate has less than 7 days of validity left.
- Combines the `.crt` and `.key` into a `.pem` file, rebuilt only when the source files are newer than it (or it's missing) - not on every run.

#### 3. **Web Server Integration**

- Points `/etc/lighttpd/custom-cert.pem` at the PEM file - **not** `https-cert.pem` directly. WAGO's own `/etc/init.d/lighttpd` unconditionally re-symlinks `https-cert.pem` to `custom-cert.pem` (if present) or the factory `default-cert.pem` on every start/reload, so writing to `https-cert.pem` directly gets silently clobbered the moment lighttpd restarts. This was found by testing on a live PFC300: the script reported success, but the browser kept showing WAGO's factory certificate until the target was corrected to `custom-cert.pem`, which is WAGO's actual "bring your own certificate" hook and survives restarts.
- Only reloads/restarts `lighttpd` when the certificate content or the `custom-cert.pem` symlink target actually changed - a routine cron run that finds nothing to renew doesn't restart the web server.

#### Bugs found and fixed during testing on real hardware

- **Missing PEM staleness check**: a renewed `.crt`/`.key` never got recombined into the PEM lighttpd actually reads, once the PEM existed once.
- **Wrong lighttpd target** (`https-cert.pem` instead of `custom-cert.pem`) - see above.
- **`mv` under `set -e`**: backing up an existing cert file with `mv` aborted the whole script if nothing existed yet at the target (e.g. first run on a device with no prior custom cert). Now guarded with an existence check.
- **openssl stdout leak**: `openssl x509 -checkend ... -noout` prints its own "Certificate will/will not expire" line even with `-noout` (that flag only suppresses the certificate dump). Left unredirected, that text got captured into the same variable as the script's own `echo "valid"`, so the equality check never matched and the script always believed renewal was needed, regardless of actual expiry.
- **Unconditional lighttpd restart**: previously reloaded/restarted lighttpd on every run, even when nothing changed. Now gated behind an actual content or symlink-target change.

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

---

# update_tailscale_certificates_and_opcua.sh

**Status: experimental / unverified - do not deploy via cron as-is.** This script extends the same certificate logic to also push the Tailscale certificate into the CODESYS OPC UA server's PKI store (`/home/codesys_root/.pki/own/{cert,key}`), converted to DER, and restarts the CODESYS runtime. The `lighttpd` half shares every fix listed above for `update_tailscale_certificates.sh` and is equally trustworthy. **The OPC UA half is not confirmed to work, and the available evidence suggests it likely doesn't**, at least not without further work:

- WAGO support has stated the CODESYS OPC UA Server (as opposed to the WAGO OPC UA Server / e!COCKPIT-based firmware) does not support the GDS certificate-push mechanism ([WAGO community, "OPC UA Certificates"](https://www.wago.community/t/opc-ua-certificates/1614/6)).
- A community user reported getting a "Bad" certificate error using this *exact* approach - an OpenSSL-generated certificate converted to DER - even after explicitly trusting it in UaExpert ([WAGO community, "Tech Note: 3S Runtime with OPC UA Server", post #9](https://www.wago.community/t/tech-note-3s-runtime-with-opc-ua-server/305/9)).
- OPC UA servers validate that the certificate's `SubjectAltName` includes a URI matching the server's `ApplicationUri` ([WAGO community, "PFC100 OPC UA - CA Certificate handling"](https://www.wago.community/t/pfc100-opc-ua-ca-certificate-handling/816/6)). A Tailscale/Let's Encrypt certificate only ever carries a DNS SAN, never a URI SAN - this isn't fixable by changing the file format or location, it's a different kind of certificate than what OPC UA expects.
- CODESYS may regenerate its own self-signed identity certificate on runtime restart regardless of what other files are present in the PKI directory, so it's unclear whether a dropped-in file would even be picked up.
- Live-tested on a PFC300 with a real, running OPC UA server (confirmed reachable and browsable via UaExpert on `opc.tcp://<host>:4840`): the server could not establish *any* Sign/Encrypt session using its own pre-existing default certificate (`ApplicationUri` reported empty, `BadServiceUnsupported` returned on session creation) - a problem that exists independently of anything this script does, and that would need to be resolved first before this script's approach could even be meaningfully tested.

#### Bugs found and fixed (independent of the OPC UA question above)

Same lighttpd-related fixes as `update_tailscale_certificates.sh` (wrong symlink target, `mv` under `set -e`, openssl stdout leak, unconditional reload), plus:

- **DER conversion**: the original did `cp -f` from the PEM-encoded `.crt`/`.key` straight to `.der`-named files - that changes the filename, not the encoding. A file full of `-----BEGIN CERTIFICATE-----` text named `.der` is not valid DER and fails to parse as one (verified locally: `openssl x509 -inform DER` rejects it). Fixed with proper `openssl x509 -outform DER` / `openssl pkey -outform DER` conversion.
- **Wrong restart command**: `systemctl restart codesys.service` - there is no such systemd unit on WAGO PTXdist controllers (confirmed on a real PFC300; the runtime is managed by `/etc/init.d/runtime`, an init.d script implementing only `start`/`stop`, no `restart`). This silently no-op'd every time. Fixed to call `stop` then `start` explicitly. Note this genuinely stops the running PLC control program for several seconds (graceful stop, then SIGKILL after a 10s timeout) - not a lightweight service bounce.
- **Unconditional OPC UA update and runtime restart**: previously rewrote the OPC UA certificate files and restarted the CODESYS runtime (stopping live control logic) on every single run, even when nothing had changed. Now gated behind the same "did the certificate actually change" check as the lighttpd half.

Treat this script as a documented starting point for OPC UA certificate provisioning, not a working solution, until someone actually verifies an OPC UA client can connect using the resulting certificate on a device where secured OPC UA connections are already confirmed to work at all.
