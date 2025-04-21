#!/bin/bash

#===============================================================================
# Trojan-Go 自动部署脚本
# 作者: ChatGPT
# 环境: Bash 4+
# 说明: 自动安装并配置 Trojan-Go 服务，包括 SSL 证书和伪装网站
# 执行方式： sudo bash trojan-install.sh -d your-domain.com -e your@email.com
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#-----------------------------
# 配置变量（可根据需要修改）
#-----------------------------
DOMAIN=""
EMAIL=""
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
    echo "用法: $0 -d <your-domain.com> -e <email@example.com>"
    echo "参数说明："
    echo "  -d    设置绑定的域名（必须已解析到本机 IP）"
    echo "  -e    用于申请 Let's Encrypt 证书的邮箱"
    echo "  -h    显示此帮助信息"
    exit 1
}

#-----------------------------
# 参数解析
#-----------------------------
while getopts ":d:e:h" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        e) EMAIL="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    usage
fi

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
    server_name $DOMAIN;
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
# 获取 SSL 证书
#-----------------------------
log "申请 SSL 证书..."
certbot certonly --nginx --agree-tos --no-eff-email -m "$EMAIL" -d "$DOMAIN" || error_exit "证书申请失败"

CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

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
cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["$(openssl rand -hex 16)"],
  "ssl": {
    "cert": "/etc/trojan-go/server.crt",
    "key": "/etc/trojan-go/server.key",
    "sni": "$DOMAIN",
    "fallback_addr": "127.0.0.1",
    "fallback_port": 80
  },
  "tcp": {
    "prefer_ipv4": true
  }
}
EOF

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
cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/trojan-go/server.crt
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/trojan-go/server.key
chmod 644 /etc/trojan-go/server.crt
chmod 600 /etc/trojan-go/server.key
systemctl restart trojan-go
EOF

chmod +x "$HOOK_SCRIPT"

#-----------------------------
# 完成信息
#-----------------------------
log "部署完成！Trojan-Go 正在运行。"
log "证书路径: $CERT_PATH"
log "配置文件: /etc/trojan-go/config.json"
log "日志文件: $LOG_FILE"
log "请记下配置密码并妥善保管。"
