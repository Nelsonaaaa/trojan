#!/bin/bash

# ========= 设置 =========
read -p "请输入你的域名（已解析到当前 VPS）: " DOMAIN
read -p "请输入你设置的 Trojan 密码: " PASSWORD

# ========= 安装依赖 =========
echo "\n[1/7] 更新系统 & 安装依赖..."
yum update -y && yum install -y epel-release curl unzip nginx socat git firewalld

# ========= 启用防火墙 =========
echo "\n[2/7] 开放防火墙端口..."
systemctl enable firewalld --now
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

# ========= 安装 acme.sh 获取 TLS 证书 =========
echo "\n[3/7] 安装 acme.sh 获取 HTTPS 证书..."
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256 --force
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
  --ecc \
  --key-file /etc/ssl/private/trojan.key \
  --fullchain-file /etc/ssl/certs/trojan.crt \
  --reloadcmd "systemctl restart trojan-go nginx"

# ========= 安装 Trojan-Go =========
echo "\n[4/7] 安装 Trojan-Go..."
mkdir -p /etc/trojan-go
cd /etc/trojan-go
LATEST=$(curl -s https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest | grep browser_download_url | grep linux-amd64.zip | cut -d '"' -f 4)
curl -LO $LATEST
unzip *.zip && rm -f *.zip

# ========= 配置 Trojan-Go =========
echo "\n[5/7] 配置 Trojan-Go..."
cat > /etc/trojan-go/config.json <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
  "password": [
    "$PASSWORD"
  ],
  "ssl": {
    "cert": "/etc/ssl/certs/trojan.crt",
    "key": "/etc/ssl/private/trojan.key",
    "sni": "$DOMAIN"
  },
  "websocket": {
    "enabled": false
  }
}
EOF

# ========= 配置 systemd 启动服务 =========
cat > /etc/systemd/system/trojan-go.service <<EOF
[Unit]
Description=Trojan-Go Service
After=network.target

[Service]
Type=simple
ExecStart=/etc/trojan-go/trojan-go -config /etc/trojan-go/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable trojan-go
systemctl start trojan-go

# ========= 配置 Nginx 显示维护页 =========
echo "\n[6/7] 配置 Nginx 伪装页面..."
cat > /usr/share/nginx/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>此站正在维护中</title>
</head>
<body style="text-align:center;margin-top:10%">
  <h1>🚧 此站正在维护中 🚧</h1>
  <p>请稍后访问</p>
</body>
</html>
EOF

systemctl enable nginx
systemctl restart nginx

# ========= 完成 =========
echo "\n[7/7] 部署完成 ✅"
echo "Trojan-Go 运行中，已使用 TLS 证书"
echo "你的域名：$DOMAIN"
echo "Trojan 密码：$PASSWORD"
echo "端口：443"
echo "伪装页面：http://$DOMAIN"
