#!/bin/bash

#===============================================================================
# Trojan-Go Advanced Auto-Deployment Script
# Version: 2.1 (State management and UFW check enhanced)
# Based on discussions with the user.
#
# Features:
# - Trojan-Go (latest version)
# - Nginx fallback site
# - Let's Encrypt SSL certificate via Certbot
# - UFW firewall configuration (checks if active before enabling)
# - BBR congestion control enablement
# - Customizable system upgrade behavior
# - Secure certificate permissions and ownership for Trojan-Go service
# - Detailed client configuration output
# - Certbot auto-renewal hook for Trojan-Go
# - Resumability: Skips completed steps on re-execution after failure.
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
STATE_FILE="/var/log/trojan-go-install.state" # For resumability
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
TROJAN_PASSWORD="" # Initialize, will be set or retrieved

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
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

# State Management Helper Functions
is_step_completed() {
    local step_name="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        touch "$STATE_FILE" || error_exit "Cannot create state file $STATE_FILE. Check permissions."
    fi
    if grep -Fxq "$step_name" "$STATE_FILE"; then
        return 0 # True, step completed
    else
        return 1 # False, step not completed
    fi
}

mark_step_completed() {
    local step_name="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        touch "$STATE_FILE" || error_exit "Cannot write to state file $STATE_FILE (during mark_step_completed). Check permissions."
    fi
    if ! is_step_completed "$step_name"; then # Avoid duplicate entries
        echo "$step_name" >> "$STATE_FILE"
        log "Step '$step_name' marked as completed."
    fi
}

run_step() {
    local step_name="$1"
    local function_to_call="$2"
    local func_args=("${@:3}") # Pass remaining arguments to the function

    if is_step_completed "$step_name"; then
        log "Skipping already completed step: $step_name"
        return 0
    fi

    log "Executing step: $step_name (Function: $function_to_call)..."
    # Call the function. If it fails, set -e will cause script to exit.
    # The function itself should use `|| error_exit "..."` for critical commands or rely on set -e.
    if "$function_to_call" "${func_args[@]}"; then
        mark_step_completed "$step_name"
        log "Step '$step_name' completed successfully."
    else
        # This part is reached if the function returns a non-zero status explicitly
        # and `set -e` didn't cause an immediate exit (e.g., if `set +e` was used in the function).
        error_exit "Step '$step_name' (Function: $function_to_call) failed. Review logs."
    fi
}

#-----------------------------
# Step Functions
#-----------------------------
step_initial_prerequisites() {
    log "Performing initial prerequisite checks..."
    [[ $EUID -ne 0 ]] && error_exit "This script must be run as root. Please use sudo."

    log "Checking domain resolution for $DOMAIN..."
    SERVER_IP=$(curl -s ip.sb || curl -s ifconfig.me || curl -s api.ipify.org)
    DOMAIN_IP=$(dig +short "$DOMAIN" A | head -n1)

    if [[ -z "$SERVER_IP" ]]; then
        warn "Could not determine server's public IP. Skipping domain IP check."
    elif [[ -z "$DOMAIN_IP" ]]; then
        error_exit "Domain $DOMAIN does not resolve to any IP address. Please check your DNS settings."
    elif [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
        error_exit "Domain $DOMAIN resolves to $DOMAIN_IP, but server's public IP appears to be $SERVER_IP. Please ensure the domain points to this server."
    else
        log "Domain $DOMAIN correctly resolves to $SERVER_IP."
    fi
}

step_system_update_lists() {
    log "Updating package lists..."
    apt-get update -y || error_exit "Failed to update package lists."
}

step_system_upgrade_packages() {
    if [ "$SKIP_UPGRADE" = true ]; then
        log "Skipping system upgrade as per user request."
        # This step is effectively skipped by user choice, mark as complete so it's not re-attempted
    else
        log "Upgrading system packages... This may take a while."
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || error_exit "Failed to upgrade system packages."
    fi
}

step_install_core_dependencies() {
    log "Installing core dependencies: curl, jq, wget, unzip..."
    for pkg in curl jq wget unzip; do
        if ! check_command "$pkg"; then
            apt-get install -y "$pkg" || error_exit "Failed to install $pkg."
        else
            log "$pkg is already installed."
        fi
    done
}

step_install_main_dependencies() {
    log "Installing main dependencies: ufw, nginx, certbot, python3-certbot-nginx..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw nginx certbot python3-certbot-nginx || error_exit "Failed to install main dependencies."
}

step_enable_bbr() {
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
}

step_configure_ufw_rules() {
    log "Configuring UFW rules..."
    ufw allow ssh || warn "Failed to allow SSH. Check UFW status."
    ufw allow http || warn "Failed to allow HTTP (80/tcp). Check UFW status."
    ufw allow https || warn "Failed to allow HTTPS (443/tcp). Check UFW status."
}

step_enable_ufw_if_needed() {
    log "Checking UFW status and enabling if necessary..."
    if ! ufw status | grep -qw active; then
        log "UFW is not active. Attempting to enable..."
        # Use 'yes' to automatically answer the confirmation prompt for enabling UFW
        yes | ufw enable || error_exit "Failed to enable UFW. 'ufw enable' command failed."
        log "UFW has been enabled."
    else
        log "UFW is already active."
    fi
    ufw status verbose
    log "UFW configuration complete."
}

step_setup_nginx_fallback_site() {
    log "Configuring Nginx fallback site..."
    mkdir -p "$NGINX_FALLBACK_ROOT" || error_exit "Failed to create Nginx fallback root directory: $NGINX_FALLBACK_ROOT"
    cat > "${NGINX_FALLBACK_ROOT}/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body><h1>Site under construction.</h1><p>This is a placeholder page.</p></body>
</html>
EOF

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
}
EOF
    log "Nginx fallback site files created."
}

step_test_reload_nginx() {
    log "Testing Nginx configuration..."
    nginx -t || error_exit "Nginx configuration test failed. Please check $NGINX_FALLBACK_CONF_FILE and other Nginx configs."
    log "Reloading Nginx service..."
    systemctl reload nginx || systemctl restart nginx || error_exit "Failed to reload/restart Nginx."
    log "Nginx fallback site configured and Nginx reloaded."
}

step_acquire_ssl_certificate() {
    log "Acquiring SSL certificate for $DOMAIN using Certbot..."
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
}

step_install_trojan_go() {
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

    rm -rf "$TEMP_DIR"
    log "Trojan-Go ${LATEST_TROJAN_GO_TAG} installed successfully to ${TROJAN_GO_INSTALL_DIR}/trojan-go."
}

step_configure_trojan_go_certs() {
    log "Configuring Trojan-Go SSL certificates..."
    CERT_PATH_LIVE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem" # Ensure these are defined if step is run standalone
    KEY_PATH_LIVE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    if [[ ! -f "$CERT_PATH_LIVE" || ! -f "$KEY_PATH_LIVE" ]]; then
         error_exit "Live SSL certificate files not found for Trojan-Go configuration. Cert acquisition might have failed or paths are incorrect. Expected: $CERT_PATH_LIVE, $KEY_PATH_LIVE"
    fi

    cp "$CERT_PATH_LIVE" "$TROJAN_GO_CERT_FILE" || error_exit "Failed to copy certificate to $TROJAN_GO_CERT_FILE."
    cp "$KEY_PATH_LIVE" "$TROJAN_GO_KEY_FILE" || error_exit "Failed to copy private key to $TROJAN_GO_KEY_FILE."

    chmod 644 "$TROJAN_GO_CERT_FILE" || error_exit "Failed to set permissions for $TROJAN_GO_CERT_FILE."
    chmod 600 "$TROJAN_GO_KEY_FILE" || error_exit "Failed to set permissions for $TROJAN_GO_KEY_FILE."
    chown nobody:nogroup "$TROJAN_GO_CERT_FILE" "$TROJAN_GO_KEY_FILE" || error_exit "Failed to set ownership for Trojan-Go certificates (nobody:nogroup)."
    log "Trojan-Go SSL certificates configured."
}

step_generate_trojan_go_config_file() {
    log "Generating Trojan-Go configuration file..."
    # This global variable will be set here. If this step is skipped on a re-run,
    # TROJAN_PASSWORD will be retrieved from the config file later.
    TROJAN_PASSWORD=$(openssl rand -hex 16)
    log "Generated new Trojan password." # Log this only if a new one is truly generated.

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
    log "Trojan-Go configuration file created at ${TROJAN_GO_CONFIG_DIR}/config.json."
}

step_create_trojan_go_systemd_service() {
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

[Install]
WantedBy=multi-user.target
EOF
    log "Trojan-Go Systemd service file created."
}

step_start_enable_trojan_go_service() {
    log "Reloading Systemd daemon, enabling and starting Trojan-Go service..."
    systemctl daemon-reload || error_exit "Failed to reload systemd daemon."
    systemctl enable trojan-go.service || error_exit "Failed to enable Trojan-Go service."
    systemctl start trojan-go.service || error_exit "Failed to start Trojan-Go service."

    sleep 2 # Give service a moment
    if systemctl is-active --quiet trojan-go.service; then
        log "Trojan-Go service is active and running."
    else
        # Changed to warn to not make the whole script fail if service has a hiccup but might be recoverable
        warn "Trojan-Go service may not be running correctly. Check with: sudo systemctl status trojan-go && sudo journalctl -u trojan-go -e"
        # Consider if this should be an error_exit depending on strictness
    fi
}

step_setup_certbot_renewal_hook() {
    log "Setting up Certbot auto-renewal hook for Trojan-Go..."
    mkdir -p "$CERTBOT_HOOK_DIR" || error_exit "Failed to create Certbot hook directory."

    cat > "$CERTBOT_HOOK_FILE" <<EOF
#!/bin/bash
# Certbot renewal hook for Trojan-Go

DOMAIN_HOOK="$DOMAIN"
CERT_PATH_LIVE_HOOK="/etc/letsencrypt/live/\$DOMAIN_HOOK/fullchain.pem"
KEY_PATH_LIVE_HOOK="/etc/letsencrypt/live/\$DOMAIN_HOOK/privkey.pem"
TROJAN_GO_CERT_FILE_HOOK="${TROJAN_GO_CONFIG_DIR}/server.crt"
TROJAN_GO_KEY_FILE_HOOK="${TROJAN_GO_CONFIG_DIR}/server.key"
LOG_FILE_HOOK="${LOG_FILE}.renewal_hook.log"

echo "[\$(date)] Certbot renewal hook for Trojan-Go triggered for \$DOMAIN_HOOK" >> "\$LOG_FILE_HOOK"
cp "\$CERT_PATH_LIVE_HOOK" "\$TROJAN_GO_CERT_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
cp "\$KEY_PATH_LIVE_HOOK" "\$TROJAN_GO_KEY_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
chmod 644 "\$TROJAN_GO_CERT_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
chmod 600 "\$TROJAN_GO_KEY_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
chown nobody:nogroup "\$TROJAN_GO_CERT_FILE_HOOK" "\$TROJAN_GO_KEY_FILE_HOOK" >> "\$LOG_FILE_HOOK" 2>&1
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
}


#-----------------------------
# Argument Parsing
#-----------------------------
for arg in "$@"; do
  shift
  case "$arg" in
    "--skip-upgrade") set -- "$@" "-s" ;;
    *)        set -- "$@" "$arg" ;;
  esac
done

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

if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    error_exit "Invalid domain name format: $DOMAIN"
fi
if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    error_exit "Invalid email address format: $EMAIL"
fi

#-----------------------------
# Main Execution Block
#-----------------------------
log "Starting Trojan-Go Advanced Deployment Script (v2.1)..."
# Ensure log and state files are accessible early
touch "$LOG_FILE" || error_exit "Cannot write to log file $LOG_FILE. Check permissions."
touch "$STATE_FILE" || error_exit "Cannot create/access state file $STATE_FILE. Check permissions."
log "Full installation log will be available at $LOG_FILE"
log "Installation state will be tracked in $STATE_FILE"

run_step "initial_prerequisites" step_initial_prerequisites
run_step "system_update_lists" step_system_update_lists
run_step "system_upgrade_packages" step_system_upgrade_packages # Respects SKIP_UPGRADE
run_step "install_core_dependencies" step_install_core_dependencies
run_step "install_main_dependencies" step_install_main_dependencies
run_step "enable_bbr" step_enable_bbr
run_step "configure_ufw_rules" step_configure_ufw_rules
run_step "enable_ufw_if_needed" step_enable_ufw_if_needed # Checks UFW status before enabling
run_step "setup_nginx_fallback_site" step_setup_nginx_fallback_site
run_step "test_reload_nginx" step_test_reload_nginx
run_step "acquire_ssl_certificate" step_acquire_ssl_certificate
run_step "install_trojan_go" step_install_trojan_go
run_step "configure_trojan_go_certs" step_configure_trojan_go_certs
run_step "generate_trojan_go_config_file" step_generate_trojan_go_config_file # Sets global TROJAN_PASSWORD
run_step "create_trojan_go_systemd_service" step_create_trojan_go_systemd_service
run_step "start_enable_trojan_go_service" step_start_enable_trojan_go_service
run_step "setup_certbot_renewal_hook" step_setup_certbot_renewal_hook

# Retrieve Trojan Password if the generation step was completed in a previous run
# and thus TROJAN_PASSWORD variable wasn't set in the current script instance by step_generate_trojan_go_config_file
if [[ -z "$TROJAN_PASSWORD" ]] && is_step_completed "generate_trojan_go_config_file"; then
    if [[ -f "${TROJAN_GO_CONFIG_DIR}/config.json" ]]; then
        # Ensure jq is available (should be, from core_dependencies step)
        if ! check_command jq; then
             error_exit "jq command not found, cannot retrieve password from config. 'core_dependencies' step might have failed or been skipped incorrectly."
        fi
        password_from_config=$(jq -r '.password[0]' "${TROJAN_GO_CONFIG_DIR}/config.json" 2>/dev/null)
        if [[ -n "$password_from_config" && "$password_from_config" != "null" ]]; then
            TROJAN_PASSWORD="$password_from_config"
            log "Retrieved Trojan password from existing config file for final display."
        else
            error_exit "FATAL: Step 'generate_trojan_go_config_file' completed, but cannot read password from ${TROJAN_GO_CONFIG_DIR}/config.json. File might be corrupt or password missing."
        fi
    else
        error_exit "FATAL: Step 'generate_trojan_go_config_file' completed, but config file ${TROJAN_GO_CONFIG_DIR}/config.json is missing."
    fi
elif [[ -z "$TROJAN_PASSWORD" ]] && ! is_step_completed "generate_trojan_go_config_file"; then
    # This case implies the script is about to report success, but the password isn't known
    # and the step to create it wasn't done. This shouldn't happen if all steps are prerequisites for success.
    TROJAN_PASSWORD="<ERROR_PASSWORD_NOT_SET_AND_GENERATION_STEP_INCOMPLETE_CHECK_LOGS>"
    warn "Trojan password could not be determined. The configuration or installation might be incomplete."
fi


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
log "   PLEASE SAVE THIS PASSWORD SECURELY."
log " - Configuration file: ${TROJAN_GO_CONFIG_DIR}/config.json"
log " - Trojan-Go service log: sudo journalctl -u trojan-go -f"
log " - Nginx fallback site root: $NGINX_FALLBACK_ROOT"
log " - SSL certificates are managed by Certbot and will auto-renew."
log "   The renewal hook will automatically update Trojan-Go's certificates."
log " - This installation log: $LOG_FILE"
log " - Installation state file (for resumability): $STATE_FILE"
log ""

# Generate Clash client configuration
CLIENT_PROXY_NAME="TrojanGo-${DOMAIN//./_}" 
CLASH_CONFIG_FILENAME="clash_config_${CLIENT_PROXY_NAME}.yaml"

log "Generating Clash Client Configuration file: $CLASH_CONFIG_FILENAME"
log "-------------------------------------------------------------------"

CLASH_CONFIG_CONTENT=$(cat << EOF
port: 7890
socks-port: 7891
allow-lan: true
bind-address: 0.0.0.0
mode: rule
log-level: warning
external-controller: 127.0.0.1:9090
ipv6: false

dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  enhanced-mode: fake-ip
  default-nameserver:
    - 223.5.5.5
    - 8.8.8.8
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
    - tls://dns.google
  fallback:
    - tls://1.1.1.1:853
    - tls://8.8.4.4:853
  fallback-filter:
    geoip: true
    geoip-code: CN

proxies:
    
  - name: ${CLIENT_PROXY_NAME}
    type: trojan
    server: ${DOMAIN}
    port: 443
    password: "${TROJAN_PASSWORD}"
    sni: ${DOMAIN}
    skip-cert-verify: false # Changed to false as we use trusted Let's Encrypt
    udp: true
    # mtu: 1200 # Often not needed, can be client-specific

proxy-groups:
  - name: 😸Selections
    type: select
    proxies:
      - ${CLIENT_PROXY_NAME}
      - DIRECT

rule-providers:
  direct:
    type: http
    behavior: domain
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt"
    path: ./ruleset/direct.yaml
    interval: 86400
  reject:
    type: http
    behavior: domain
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt"
    path: ./ruleset/reject.yaml
    interval: 86400
  private:
    type: http
    behavior: domain
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/private.txt"
    path: ./ruleset/private.yaml
    interval: 86400
  lancidr:
    type: http
    behavior: ipcidr
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/lancidr.txt"
    path: ./ruleset/lancidr.yaml
    interval: 86400
  cncidr:
    type: http
    behavior: ipcidr
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt"
    path: ./ruleset/cncidr.yaml
    interval: 86400

rules:
  - RULE-SET,private,DIRECT
  - RULE-SET,lancidr,DIRECT
  - RULE-SET,direct,DIRECT
  - RULE-SET,cncidr,DIRECT
  - RULE-SET,reject,REJECT
  - GEOIP,CN,DIRECT
  - MATCH,😸Selections
EOF
)

echo "$CLASH_CONFIG_CONTENT" > "./$CLASH_CONFIG_FILENAME"

if [ $? -eq 0 ]; then
    log "Clash client configuration successfully saved to: $(pwd)/$CLASH_CONFIG_FILENAME"
else
    warn "Failed to save Clash client configuration to a file. Please copy it manually from the log or console."
fi
log "-------------------------------------------------------------------"
log "You can find the ready-to-use Clash configuration file at: $(pwd)/$CLASH_CONFIG_FILENAME"
log ""

log "To clear installation state for a full re-run (e.g., after uninstall or for testing):"
log "  sudo rm ${STATE_FILE}"
log ""
# Uninstall instructions remain commented out as in original
<!--
log "To Uninstall Trojan-Go (Manual Steps):"
...
-->
log "==================================================================="

exit 0
