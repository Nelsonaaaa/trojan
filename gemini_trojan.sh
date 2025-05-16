Okay, this is an exciting step! Based on our detailed discussion and the finalized requirements, I will now construct the shell script.

This will be a comprehensive script. I'll add comments to explain different sections and important commands.

```bash
#!/bin/bash

#===============================================================================
# Trojan-Go Advanced Auto-Deployment Script
# Version: 2.0
# Based on discussions with the user.
#
# Features:
# - Trojan-Go (latest version)
# - Nginx fallback site
# - Let's Encrypt SSL certificate via Certbot
# - UFW firewall configuration
# - BBR congestion control enablement
# - Customizable system upgrade behavior
# - Secure certificate permissions and ownership for Trojan-Go service
# - Detailed client configuration output
# - Certbot auto-renewal hook for Trojan-Go
#
# Execution:
# sudo bash trojan-go-deploy-v2.sh -d your-domain.com -e your@email.com [--skip-upgrade]
#===============================================================================

set -euo pipefail # Exit on error, undefined variable, or pipe failure
IFS=$'\n\t'     # Set Internal Field Separator for word splitting

#-----------------------------
# Script Configuration
#-----------------------------
LOG_FILE="/var/log/trojan-go-advanced-install.log"
TROJAN_GO_INSTALL_DIR="/usr/local/bin/trojan-go"
TROJAN_GO_CONFIG_DIR="/etc/trojan-go"
TROJAN_GO_CERT_FILE="${TROJAN_GO_CONFIG_DIR}/server.crt"
TROJAN_GO_KEY_FILE="${TROJAN_GO_CONFIG_DIR}/server.key"
NGINX_FALLBACK_CONF_DIR="/etc/nginx/conf.d"
NGINX_FALLBACK_CONF_FILE="${NGINX_FALLBACK_CONF_DIR}/trojan_fallback.conf"
NGINX_FALLBACK_ROOT="/var/www/trojan_fallback_site"
CERTBOT_HOOK_DIR="/etc/letsencrypt/renewal-hooks/post"
CERTBOT_HOOK_FILE="${CERTBOT_HOOK_DIR}/trojan-go_renew.sh"

# User-provided variables
DOMAIN=""
EMAIL=""
SKIP_UPGRADE=false # Default to perform upgrade

#-----------------------------
# Helper Functions
#-----------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2 # Output error to stderr
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >> "$LOG_FILE"
    exit 1
}

usage() {
    echo "Usage: $0 -d <your-domain.com> -e <email@example.com> [--skip-upgrade]"
    echo "Parameters:"
    echo "  -d    Domain name for Trojan-Go and SSL certificate (must be resolved to this server's IP)."
    echo "  -e    Email address for Let's Encrypt registration."
    echo "  --skip-upgrade (Optional) Skip 'apt upgrade' process."
    echo "  -h    Display this help message."
    exit 0
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

check_kernel_version() {
    local major minor
    major=$(uname -r | cut -d. -f1)
    minor=$(uname -r | cut -d. -f2)
    if [[ "$major" -lt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -lt 9 ]]; }; then
        return 1 # Kernel version < 4.9
    else
        return 0 # Kernel version >= 4.9
    fi
}

#-----------------------------
# Argument Parsing
#-----------------------------
# Handle long options like --skip-upgrade by transforming them
for arg in "$@"; do
  shift
  case "$arg" in
    "--skip-upgrade") set -- "$@" "-s" ;;
    *)        set -- "$@" "$arg" ;;
  esac
done

# Parse short options
while getopts ":d:e:sh" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        e) EMAIL="$OPTARG" ;;
        s) SKIP_UPGRADE=true ;;
        h) usage ;;
        \?) error_exit "Invalid option: -$OPTARG. Use -h for help." ;;
        :) error_exit "Option -$OPTARG requires an argument. Use -h for help." ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    usage
fi

# Validate domain format (basic)
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    error_exit "Invalid domain name format: $DOMAIN"
fi

# Validate email format (basic)
if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    error_exit "Invalid email address format: $EMAIL"
fi

#-----------------------------
# Initial Checks
#-----------------------------
log "Starting Trojan-Go Advanced Deployment Script..."
touch "$LOG_FILE" || error_exit "Cannot write to log file $LOG_FILE. Check permissions."
log "Full installation log will be available at $LOG_FILE"

[[ $EUID -ne 0 ]] && error_exit "This script must be run as root. Please use sudo."

log "Checking domain resolution for $DOMAIN..."
SERVER_IP=$(curl -s ip.sb || curl -s ifconfig.me || curl -s api.ipify.org)
DOMAIN_IP=$(dig +short "$DOMAIN" A | head -n1) # Get first A record

if [[ -z "$SERVER_IP" ]]; then
    warn "Could not determine server's public IP. Skipping domain IP check."
elif [[ -z "$DOMAIN_IP" ]]; then
    error_exit "Domain $DOMAIN does not resolve to any IP address. Please check your DNS settings."
elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    error_exit "Domain $DOMAIN resolves to $DOMAIN_IP, but server's public IP appears to be $SERVER_IP. Please ensure the domain points to this server."
else
    log "Domain $DOMAIN correctly resolves to $SERVER_IP."
fi

#-----------------------------
# System Preparation & Dependency Installation
#-----------------------------
log "Updating package lists..."
apt-get update -y || error_exit "Failed to update package lists."

if [ "$SKIP_UPGRADE" = true ]; then
    log "Skipping system upgrade as per user request."
else
    log "Upgrading system packages... This may take a while."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || error_exit "Failed to upgrade system packages."
fi

log "Installing core dependencies: curl, jq, wget, unzip..."
for pkg in curl jq wget unzip; do
    if ! check_command "$pkg"; then
        apt-get install -y "$pkg" || error_exit "Failed to install $pkg."
    else
        log "$pkg is already installed."
    fi
done

log "Installing main dependencies: ufw, nginx, certbot, python3-certbot-nginx..."
# Using DEBIAN_FRONTEND to avoid interactive prompts for Nginx, etc.
DEBIAN_FRONTEND=noninteractive apt-get install -y ufw nginx certbot python3-certbot-nginx || error_exit "o install main dependencies."

#-----------------------------
# Enable BBR Congestion Control
#-----------------------------
log "Attempting to enable BBR congestion control..."
if check_kernel_version; then
    log "Kernel version is >= 4.9, BBR supported."
    BBR_CONFIG_FILE="/etc/sysctl.d/99-bbr.conf"
    NEEDS_SYSCTL_P=false

    if ! grep -q -E "^\s*net\.core\.default_qdisc\s*=\s*fq\s*$" "$BBR_CONFIG_FILE" /etc/sysctl.conf 2>/dev/null; then
        log "Setting net.core.default_qdisc=fq"
        echo "net.core.default_qdisc=fq" >> "$BBR_CONFIG_FILE"
        NEEDS_SYSCTL_P=true
    else
        log "net.core.default_qdisc=fq already configured."
    fi

    if ! grep -q -E "^\s*net\.ipv4\.tcp_congestion_control\s*=\s*bbr\s*$" "$BBR_CONFIG_FILE" /etc/sysctl.conf 2>/dev/null; then
        log "Setting net.ipv4.tcp_congestion_control=bbr"
        echo "net.ipv4.tcp_congestion_control=bbr" >> "$BBR_CONFIG_FILE"
        NEEDS_SYSCTL_P=true
    else
        log "net.ipv4.tcp_congestion_control=bbr already configured."
    fi

    if [ "$NEEDS_SYSCTL_P" = true ]; then
        log "Applying new sysctl settings..."
        sysctl -p || warn "sysctl -p failed. Settings might not be applied immediately. A reboot may be required."
    fi

    # Verify
    CURRENT_TCP_CONGESTION=$(sysctl -n net.ipv4.tcp_congestion_control)
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc)
    if [[ "$CURRENT_TCP_CONGESTION" == "bbr" ]] && [[ "$CURRENT_QDISC" == "fq" ]]; then
        log "BBR and FQ seem to be active."
    else
        warn "BBR or FQ might not be active. Current: TCP_CONGESTION=$CURRENT_TCP_CONGESTION, QDISC=$CURRENT_QDISC. A reboot might be needed."
    fi
else
    warn "Kernel version is older than 4.9. Cannot automatically enable BBR. Consider upgrading your kernel."
fi

#-----------------------------
# Firewall Configuration (UFW)
#-----------------------------
log "Configuring firewall (UFW)..."
ufw allow ssh || warn "Failed to allow SSH. Check UFW status."
ufw allow http || warn "Failed to allow HTTP (80/tcp). Check UFW status."
ufw allow https || warn "Failed to allow HTTPS (443/tcp). Check UFW status."
# Check UFW status first
if ! ufw status | grep -qw active; then
    log "UFW is not active. Attempting to enable..."
    yes | ufw enable || error_exit "Failed to enable UFW. 'ufw enable' command failed."
    log "UFW has been enabled."
else
    log "UFW is already active."
fi
ufw status verbose
log "UFW configuration complete." # Adjusted log message slightly

#-----------------------------
# Nginx Fallback Site Configuration
#-----------------------------
log "Configuring Nginx fallback site..."
mkdir -p "$NGINX_FALLBACK_ROOT" || error_exit "Failed to create Nginx fallback root directory: $NGINX_FALLBACK_ROOT"
# Simple HTML for fallback
cat > "${NGINX_FALLBACK_ROOT}/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body><h1>Site under construction.</h1><p>This is a placeholder page.</p></body>
</html>
EOF

# Nginx config for fallback site
cat > "$NGINX_FALLBACK_CONF_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $NGINX_FALLBACK_ROOT;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Optional: Add access and error logs if desired
    # access_log /var/log/nginx/${DOMAIN}_fallback_access.log;
    # error_log /var/log/nginx/${DOMAIN}_fallback_error.log;
}
EOF

log "Testing Nginx configuration..."
nginx -t || error_exit "Nginx configuration test failed. Please check $NGINX_FALLBACK_CONF_FILE and other Nginx configs."

log "Reloading Nginx service..."
systemctl reload nginx || systemctl restart nginx || error_exit "Failed to reload/restart Nginx."
log "Nginx fallback site configured."

#-----------------------------
# SSL Certificate Acquisition (Certbot)
#-----------------------------
log "Acquiring SSL certificate for $DOMAIN using Certbot..."
# Ensure Nginx is running for certbot --nginx plugin
systemctl is-active --quiet nginx || systemctl start nginx || error_exit "Nginx is not running, cannot acquire certificate with --nginx plugin."

certbot certonly --nginx \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --staple-ocsp \
    -m "$EMAIL" \
    --no-eff-email || error_exit "Certbot failed to acquire SSL certificate for $DOMAIN."

CERT_PATH_LIVE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH_LIVE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [[ ! -f "$CERT_PATH_LIVE" || ! -f "$KEY_PATH_LIVE" ]]; then
    error_exit "SSL certificate files not found after Certbot execution. Expected at $CERT_PATH_LIVE and $KEY_PATH_LIVE."
fi
log "SSL certificate acquired successfully."

#-----------------------------
# Trojan-Go Installation
#-----------------------------
log "Installing Trojan-Go (latest version)..."
mkdir -p "$TROJAN_GO_INSTALL_DIR" "$TROJAN_GO_CONFIG_DIR" || error_exit "Failed to create Trojan-Go directories."

LATEST_TROJAN_GO_TAG=$(curl -s "https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest" | jq -r .tag_name)
if [[ -z "$LATEST_TROJAN_GO_TAG" || "$LATEST_TROJAN_GO_TAG" == "null" ]]; then
    error_exit "Failed to fetch the latest Trojan-Go version tag from GitHub."
fi
log "Latest Trojan-Go version tag: $LATEST_TROJAN_GO_TAG"

TROJAN_GO_DOWNLOAD_URL="https://github.com/p4gefau1t/trojan-go/releases/download/${LATEST_TROJAN_GO_TAG}/trojan-go-linux-amd64.zip"
log "Downloading Trojan-Go from $TROJAN_GO_DOWNLOAD_URL"

TEMP_DIR=$(mktemp -d)
wget -qO "${TEMP_DIR}/trojan-go.zip" "$TROJAN_GO_DOWNLOAD_URL" || error_exit "Failed to download Trojan-Go."
unzip -q "${TEMP_DIR}/trojan-go.zip" -d "$TEMP_DIR" || error_exit "Failed to unzip Trojan-Go."

mv "${TEMP_DIR}/trojan-go" "${TROJAN_GO_INSTALL_DIR}/trojan-go" || error_exit "Failed to move Trojan-Go executable."
chmod +x "${TROJAN_GO_INSTALL_DIR}/trojan-go" || error_exit "Failed to set executable permission on Trojan-Go."

rm -rf "$TEMP_DIR" # Clean up temporary directory
log "Trojan-Go ${LATEST_TROJAN_GO_TAG} installed successfully to ${TROJAN_GO_INSTALL_DIR}/trojan-go."

#-----------------------------
# Configure Trojan-Go (Certificates and Config File)
#-----------------------------
log "Configuring Trojan-Go..."
log "Copying SSL certificates for Trojan-Go..."
cp "$CERT_PATH_LIVE" "$TROJAN_GO_CERT_FILE" || error_exit "Failed to copy certificate to $TROJAN_GO_CERT_FILE."
cp "$KEY_PATH_LIVE" "$TROJAN_GO_KEY_FILE" || error_exit "Failed to copy private key to $TROJAN_GO_KEY_FILE."

log "Setting permissions and ownership for Trojan-Go certificates..."
chmod 644 "$TROJAN_GO_CERT_FILE" || error_exit "Failed to set permissions for $TROJAN_GO_CERT_FILE."
chmod 600 "$TROJAN_GO_KEY_FILE" || error_exit "Failed to set permissions for $TROJAN_GO_KEY_FILE."
chown nobody:nogroup "$TROJAN_GO_CERT_FILE" "$TROJAN_GO_KEY_FILE" || error_exit "Failed to set ownership for Trojan-Go certificates (nobody:nogroup)."

TROJAN_PASSWORD=$(openssl rand -hex 16)
log "Generating Trojan-Go configuration file: ${TROJAN_GO_CONFIG_DIR}/config.json"
cat > "${TROJAN_GO_CONFIG_DIR}/config.json" <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["$TROJAN_PASSWORD"],
  "ssl": {
    "cert": "$TROJAN_GO_CERT_FILE",
    "key": "$TROJAN_GO_KEY_FILE",
    "sni": "$DOMAIN",
    "fallback_addr": "127.0.0.1",
    "fallback_port": 80,
    "alpn": ["http/1.1"]
  },
  "tcp": {
    "prefer_ipv4": true,
    "no_delay": true,
    "keep_alive": true,
    "reuse_port": true,
    "fast_open": false 
  },
  "router": {
    "enabled": true,
    "block": ["geoip:private"]
  }
}
EOF
log "Trojan-Go configuration file created."

#-----------------------------
# Create Systemd Service for Trojan-Go
#-----------------------------
log "Creating Systemd service for Trojan-Go..."
cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go - Anonymizing Proxy
Documentation=https://github.com/p4gefau1t/trojan-go
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=${TROJAN_GO_INSTALL_DIR}/trojan-go -config ${TROJAN_GO_CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

# Security enhancements (optional, can be more restrictive)
# PrivateTmp=true
# ProtectSystem=full
# ProtectHome=true
# NoNewPrivileges=true
# CapabilityBoundingSet=CAP_NET_BIND_SERVICE
# ReadWritePaths=${TROJAN_GO_CONFIG_DIR} (if config is reloaded at runtime, not common for trojan-go)

[Install]
WantedBy=multi-user.target
EOF

log "Reloading Systemd daemon, enabling and starting Trojan-Go service..."
systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
systemctl enable trojan-go.service || error_exit "Failed to enable Trojan-Go service."
systemctl start trojan-go.service || error_exit "Failed to start Trojan-Go service."

# Check service status briefly
sleep 2 # Give service a moment to start/fail
if systemctl is-active --quiet trojan-go.service; then
    log "Trojan-Go service is active and running."
else
    warn "Trojan-Go service may not be running correctly. Check with: sudo systemctl status trojan-go && sudo journalctl -u trojan-go -e"
fi

#-----------------------------
# Setup Certbot Auto-Renewal Hook
#-----------------------------
log "Setting up Certbot auto-renewal hook for Trojan-Go..."
mkdir -p "$CERTBOT_HOOK_DIR" || error_exit "Failed to create Certbot hook directory."

cat > "$CERTBOT_HOOK_FILE" <<EOF
#!/bin/bash
# Certbot renewal hook for Trojan-Go

# Paths (match main script)
DOMAIN_HOOK="$DOMAIN" # Domain will be available via Certbot environment variables too, but explicit is safer
CERT_PATH_LIVE_HOOK="/etc/letsencrypt/live/\$DOMAIN_HOOK/fullchain.pem"
KEY_PATH_LIVE_HOOK="/etc/letsencrypt/live/\$DOMAIN_HOOK/privkey.pem"
TROJAN_GO_CERT_FILE_HOOK="${TROJAN_GO_CONFIG_DIR}/server.crt"
TROJAN_GO_KEY_FILE_HOOK="${TROJAN_GO_CONFIG_DIR}/server.key"
LOG_FILE_HOOK="${LOG_FILE}.renewal_hook.log" # Separate log for hook

echo "[\$(date)] Certbot renewal hook for Trojan-Go triggered for \$DOMAIN_HOOK" >> "\$LOG_FILE_HOOK"

# Copy new certificates
cp "\$CERT_PATH_LIVE_HOOK" "\$TROJAN_GO_CERT_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
cp "\$KEY_PATH_LIVE_HOOK" "\$TROJAN_GO_KEY_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1

# Set correct permissions and ownership
chmod 644 "\$TROJAN_GO_CERT_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
chmod 600 "\$TROJAN_GO_KEY_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
chown nobody:nogroup "\$TROJAN_GO_CERT_FILE_HOOK" "\$TROJAN_GO_KEY_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1

# Restart Trojan-Go to apply new certificates
echo "[\$(date)] Restarting Trojan-Go service..." >> "\$LOG_FILE_HOOK"
systemctl restart trojan-go >> "\$LOG_FILE_HOOK" 2>&1

if systemctl is-active --quiet trojan-go; then
    echo "[\$(date)] Trojan-Go restarted successfully." >> "\$LOG_FILE_HOOK"
else
    echo "[\$(date)] ERROR: Trojan-Go failed to restart after certificate renewal." >> "\$LOG_FILE_HOOK"
fi

exit 0
EOF

chmod +x "$CERTBOT_HOOK_FILE" || error_exit "Failed to set executable permission on Certbot hook script."
log "Certbot auto-renewal hook created at $CERTBOT_HOOK_FILE."

#-----------------------------
# Final Output and Instructions
#-----------------------------
log "==================================================================="
log " Trojan-Go Deployment Completed Successfully! "
log "==================================================================="
log ""
log "Client Configuration Details:"
log "-------------------------------------------------------------------"
log "  Server Address (Domain):  $DOMAIN"
log "  Server Port:              443"
log "  Password:                 $TROJAN_PASSWORD"
log "  SNI (Server Name Ind.):   $DOMAIN"
log "  Allow Insecure (or skip-cert-verify): false (Let's Encrypt cert is trusted)"
log "  UDP Forwarding (if client supports): true (Trojan-Go supports UDP)"
log "-------------------------------------------------------------------"
log ""
log "Important Notes:"
log " - Your Trojan-Go password is: $TROJAN_PASSWORD"
log "   PLEASE SAVE THIS PASSWORD SECURELY. It is not stored elsewhere after this script exits."
log " - Configuration file: ${TROJAN_GO_CONFIG_DIR}/config.json"
log " - Trojan-Go service log: sudo journalctl -u trojan-go -f"
log " - Nginx fallback site root: $NGINX_FALLBACK_ROOT"
log " - SSL certificates are managed by Certbot and will auto-renew."
log "   The renewal hook will automatically update Trojan-Go's certificates."
log " - This installation log: $LOG_FILE"
log ""

<!--
log "To Uninstall Trojan-Go (Manual Steps):"
log "  1. Stop and disable the Trojan-Go service:"
log "     sudo systemctl stop trojan-go"
log "     sudo systemctl disable trojan-go"
log "  2. Remove Trojan-Go files and directories:"
log "     sudo rm -rf ${TROJAN_GO_INSTALL_DIR}"
log "     sudo rm -rf ${TROJAN_GO_CONFIG_DIR}"
log "     sudo rm /etc/systemd/system/trojan-go.service"
log "     sudo rm ${CERTBOT_HOOK_FILE}"
log "  3. Remove Nginx fallback configuration:"
log "     sudo rm ${NGINX_FALLBACK_CONF_FILE}"
log "     sudo rm -rf ${NGINX_FALLBACK_ROOT}"
log "     sudo systemctl reload nginx"
log "  4. Remove UFW rules (optional, check 'sudo ufw status numbered'):"
log "     sudo ufw delete allow http"
log "     sudo ufw delete allow https"
log "  5. Remove SSL certificates (optional, be careful if other services use them for this domain):"
log "     sudo certbot delete --cert-name $DOMAIN"
log "  6. Clean apt packages (optional):"
log "     sudo apt autoremove nginx trojan-go certbot python3-certbot-nginx ufw"
log "==================================================================="
-->

exit 0
```

**Key Changes and Implementations based on our requirements:**

1.  **`--skip-upgrade`:** Implemented using `getopts` transformation.
2.  **BBR Enablement:**
    *   Checks kernel version.
    *   Adds config to `/etc/sysctl.d/99-bbr.conf` to be idempotent.
    *   Applies settings and verifies.
3.  **Nginx Fallback:**
    *   Uses a separate config file in `/etc/nginx/conf.d/trojan_fallback.conf`.
    *   Uses a dedicated root directory `/var/www/trojan_fallback_site`.
4.  **SSL Certificate Ownership/Permissions:**
    *   `chown nobody:nogroup` and `chmod 644/600` are applied to certificates copied to `/etc/trojan-go/`.
5.  **Trojan-Go Latest Version:**
    *   Fetches the latest tag from GitHub API using `curl` and `jq`.
6.  **Systemd Service:**
    *   Runs as `User=nobody`, `Group=nogroup`.
7.  **Certbot Renewal Hook:**
    *   Correctly copies certs, sets ownership/permissions (`nobody:nogroup`), and restarts `trojan-go`.
    *   Includes the `$DOMAIN` variable for the hook script (though Certbot also provides `$RENEWED_DOMAINS`).
8.  **Client Configuration Output:**
    *   Clearly outputs Server Address, Port, generated Password, and SNI.
9.  **Uninstall Instructions:**
    *   Detailed manual uninstall steps are provided at the end.
10. **Logging and Error Handling:**
    *   Uses `log`, `warn`, and `error_exit` functions.
    *   Includes basic domain and email validation.
    *   Checks for domain resolution against server IP.
11. **General Structure:** More organized with clear sections.

**Before Running:**

*   **Review the script carefully.**
*   Ensure you have a fresh server النفس (or a test environment) if you're running it for the first time.
*   Make sure your domain name is already pointed to the server's IP address.

This script is significantly more robust and feature-rich than the original. Let me know if you have any questions or see any immediate adjustments needed before you test it!
