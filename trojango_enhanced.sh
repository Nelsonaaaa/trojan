#!/bin/bash

#===============================================================================
# Trojan-Go 自动部署脚本 (增强版)
# 作者: ChatGPT
# 环境: Bash 4+
# 说明: 自动安装并配置 Trojan-Go 服务，包括 SSL 证书和伪装网站
#       增加了BBR优化、Cloudflare DNS配置和客户端密码显示
# 执行方式： sudo bash trojan-install.sh -d your-domain.com -e your@email.com -s vpn-subdomain
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#-----------------------------
# 配置变量（可根据需要修改）
#-----------------------------
DOMAIN=""
EMAIL=""
SUBDOMAIN=""
CF_API_TOKEN=""
CF_ZONE_ID=""
LOG_FILE="/var/log/trojan-go-install.log"

#-----------------------------
# 日志函数
#-----------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

#-----------------------------
# 帮助信息
#-----------------------------
usage() {
    echo "用法: $0 -d <your-domain.com> -e <email@example.com> -s <subdomain> [-t <cloudflare-token> -z <zone-id>]"
    echo "参数说明："
    echo "  -d    设置主域名（必须已解析到本机 IP）"
    echo "  -e    用于申请 Let's Encrypt 证书的邮箱"
    echo "  -s    设置用于VPN的子域名前缀（例如：vpn）"
    echo "  -t    Cloudflare API Token（可选，用于自动配置DNS）"
    echo "  -z    Cloudflare Zone ID（可选，用于自动配置DNS）"
    echo "  -h    显示此帮助信息"
    exit 1
}

#-----------------------------
# 参数解析
#-----------------------------
while getopts ":d:e:s:t:z:h" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        e) EMAIL="$OPTARG" ;;
        s) SUBDOMAIN="$OPTARG" ;;
        t) CF_API_TOKEN="$OPTARG" ;;
        z) CF_ZONE_ID="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$SUBDOMAIN" ]]; then
    usage
fi

# 构建完整的子域名
FULL_SUBDOMAIN="${SUBDOMAIN}.${DOMAIN}"

#-----------------------------
# 前置检查
#-----------------------------
[[ $EUID -ne 0 ]] && error_exit "请使用 root 用户运行此脚本。"

command -v curl >/dev/null || apt update && apt install -y curl
command -v jq >/dev/null || apt install -y jq

#-----------------------------
# 更新系统 & 安装基础软件
#-----------------------------
log "更新系统..."
apt update && apt upgrade -y

log "安装必要软件包..."
apt install -y ufw nginx certbot python3-certbot-nginx unzip wget

#-----------------------------
# 启用 BBR 拥塞控制算法
#-----------------------------
log "启用 BBR 拥塞控制算法..."
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi

if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi

sysctl -p

# 验证 BBR 是否启用
if [[ $(sysctl net.ipv4.tcp_congestion_control | grep -c bbr) -eq 1 ]]; then
    log "BBR 已成功启用"
else
    log "警告: BBR 可能未成功启用，请手动检查"
fi

#-----------------------------
# 配置 Cloudflare DNS (如果提供了API Token)
#-----------------------------
if [[ -n "$CF_API_TOKEN" && -n "$CF_ZONE_ID" ]]; then
    log "配置 Cloudflare DNS..."
    
    # 获取服务器 IP
    SERVER_IP=$(curl -s https://api.ipify.org)
    log "检测到服务器 IP: $SERVER_IP"
    
    # 为主域名创建/更新 A 记录并启用代理
    log "为主域名 $DOMAIN 配置 Cloudflare DNS (启用代理)..."
    CF_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$DOMAIN" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json")
    
    CF_RECORD_ID=$(echo "$CF_RESPONSE" | jq -r '.result[0].id // empty')
    
    if [[ -n "$CF_RECORD_ID" ]]; then
        # 更新现有记录
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":true}"
        log "已更新主域名 $DOMAIN 的 DNS 记录 (已启用代理)"
    else
        # 创建新记录
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":true}"
        log "已创建主域名 $DOMAIN 的 DNS 记录 (已启用代理)"
    fi
    
    # 为子域名创建/更新 A 记录并禁用代理 (DNS Only)
    log "为子域名 $FULL_SUBDOMAIN 配置 Cloudflare DNS (仅 DNS)..."
    CF_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$FULL_SUBDOMAIN" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json")
    
    CF_RECORD_ID=$(echo "$CF_RESPONSE" | jq -r '.result[0].id // empty')
    
    if [[ -n "$CF_RECORD_ID" ]]; then
        # 更新现有记录
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$FULL_SUBDOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":false}"
        log "已更新子域名 $FULL_SUBDOMAIN 的 DNS 记录 (仅 DNS)"
    else
        # 创建新记录
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$FULL_SUBDOMAIN\",\"content\":\"$SERVER_IP\",\"ttl\":1,\"proxied\":false}"
        log "已创建子域名 $FULL_SUBDOMAIN 的 DNS 记录 (仅 DNS)"
    fi
else
    log "未提供 Cloudflare API Token 和 Zone ID，跳过 DNS 配置"
    log "请确保手动配置以下 DNS 记录:"
    log "1. $DOMAIN -> A 记录指向服务器 IP，启用 Cloudflare 代理"
    log "2. $FULL_SUBDOMAIN -> A 记录指向服务器 IP，关闭 Cloudflare 代理 (仅 DNS)"
fi

#-----------------------------
# 配置防火墙
#-----------------------------
log "配置防火墙..."
ufw allow ssh
ufw allow http
ufw allow https
ufw --force enable

#-----------------------------
# 安装并配置 Nginx
#-----------------------------
log "配置 Nginx 伪装网站..."
cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN $FULL_SUBDOMAIN;
    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

mkdir -p /var/www/html
echo "<h1>Welcome</h1><p>This is a placeholder site for Trojan-Go.</p>" > /var/www/html/index.html
nginx -t && systemctl restart nginx

#-----------------------------
# 获取 SSL 证书 (为子域名)
#-----------------------------
log "为子域名 $FULL_SUBDOMAIN 申请 SSL 证书..."
certbot certonly --nginx --agree-tos --no-eff-email -m "$EMAIL" -d "$FULL_SUBDOMAIN" || error_exit "子域名证书申请失败"

CERT_PATH="/etc/letsencrypt/live/$FULL_SUBDOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$FULL_SUBDOMAIN/privkey.pem"

#-----------------------------
# 安装 Trojan-Go
#-----------------------------
log "下载并安装 Trojan-Go..."
TROJAN_DIR="/usr/local/bin/trojan-go"
mkdir -p /tmp/trojan-go && cd /tmp/trojan-go
wget -q https://github.com/p4gefau1t/trojan-go/releases/download/v0.10.6/trojan-go-linux-amd64.zip
unzip -q trojan-go-linux-amd64.zip
mkdir -p "$TROJAN_DIR"
mv trojan-go "$TROJAN_DIR/"
chmod +x "$TROJAN_DIR/trojan-go"
mkdir -p /etc/trojan-go

cp "$CERT_PATH" /etc/trojan-go/server.crt
cp "$KEY_PATH" /etc/trojan-go/server.key
chmod 644 /etc/trojan-go/server.crt
chmod 600 /etc/trojan-go/server.key

#-----------------------------
# 生成 Trojan-Go 配置文件
#-----------------------------
log "创建 Trojan-Go 配置文件..."
# 生成随机密码并保存
TROJAN_PASSWORD=$(openssl rand -hex 16)

cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["$TROJAN_PASSWORD"],
  "ssl": {
    "cert": "/etc/trojan-go/server.crt",
    "key": "/etc/trojan-go/server.key",
    "sni": "$FULL_SUBDOMAIN",
    "fallback_addr": "127.0.0.1",
    "fallback_port": 80
  },
  "tcp": {
    "prefer_ipv4": true
  }
}
EOF

# 保存密码到单独文件，便于查看
echo "$TROJAN_PASSWORD" > /etc/trojan-go/password.txt
chmod 600 /etc/trojan-go/password.txt

#-----------------------------
# 创建 Systemd 服务
#-----------------------------
log "创建 systemd 服务..."
cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go Service
After=network.target

[Service]
ExecStart=$TROJAN_DIR/trojan-go -config /etc/trojan-go/config.json
Restart=on-failure
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now trojan-go

#-----------------------------
# 设置证书续期钩子
#-----------------------------
log "设置自动续期钩子..."
HOOK_SCRIPT="/etc/letsencrypt/renewal-hooks/post/trojan-go.sh"
mkdir -p "$(dirname "$HOOK_SCRIPT")"

cat > "$HOOK_SCRIPT" <<EOF
#!/bin/bash
cp /etc/letsencrypt/live/$FULL_SUBDOMAIN/fullchain.pem /etc/trojan-go/server.crt
cp /etc/letsencrypt/live/$FULL_SUBDOMAIN/privkey.pem /etc/trojan-go/server.key
chmod 644 /etc/trojan-go/server.crt
chmod 600 /etc/trojan-go/server.key
systemctl restart trojan-go
EOF

chmod +x "$HOOK_SCRIPT"

#-----------------------------
# 生成客户端配置示例
#-----------------------------
log "生成客户端配置示例..."
mkdir -p /etc/trojan-go/client
cat > /etc/trojan-go/client/config.json <<EOF
{
  "run_type": "client",
  "local_addr": "127.0.0.1",
  "local_port": 1080,
  "remote_addr": "$FULL_SUBDOMAIN",
  "remote_port": 443,
  "password": ["$TROJAN_PASSWORD"],
  "ssl": {
    "sni": "$FULL_SUBDOMAIN"
  }
}
EOF

#-----------------------------
# 完成信息
#-----------------------------
log "部署完成！Trojan-Go 正在运行。"
log "主域名: $DOMAIN (已启用 Cloudflare 代理)"
log "VPN 子域名: $FULL_SUBDOMAIN (仅 DNS，不经过 Cloudflare)"
log "证书路径: $CERT_PATH"
log "配置文件: /etc/trojan-go/config.json"
log "日志文件: $LOG_FILE"

# 显示客户端配置信息
echo "============================================================"
echo "                   客户端配置信息                           "
echo "============================================================"
echo "服务器地址: $FULL_SUBDOMAIN"
echo "服务器端口: 443"
echo "密码: $TROJAN_PASSWORD"
echo "============================================================"
echo "客户端配置示例已保存至: /etc/trojan-go/client/config.json"
echo ""
echo "您可以使用以下命令查看密码: cat /etc/trojan-go/password.txt"
echo "============================================================"

# 检查服务状态
systemctl status trojan-go --no-pager
