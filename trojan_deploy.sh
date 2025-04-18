#!/bin/bash

# ========= 用户输入 =========
read -rp "请输入你的域名（必须已解析到本机IP）: " DOMAIN
read -rp "请输入你设置的 Trojan 密码（建议不低于10位）: " PASSWORD

# ========= 检查root权限 =========
if [ "$(id -u)" != "0" ]; then
   echo "⚠️ 请使用 root 用户运行此脚本"
   exit 1
fi

# ========= 安装依赖 =========
echo -e "\n[1/7] 安装必要依赖..."
yum install -y epel-release curl unzip nginx socat git firewalld vnstat >/dev/null

# ========= 启用防火墙并开放端口 =========
echo -e "\n[2/7] 配置防火墙..."
systemctl enable firewalld --now
firewall-cmd --permanent --add-port=80/tcp >/dev/null
firewall-cmd --permanent --add-port=443/tcp >/dev/null
firewall-cmd --reload

# ========= 安装 acme.sh 获取 TLS 证书 =========
echo -e "\n[3/7] 申请 TLS 证书..."
curl https://get.acme.sh | sh
source ~/.bashrc

~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256 --force
if [ $? -ne 0 ]; then
  echo "❌ 证书申请失败，请检查域名是否正确指向本机 IP。"
  exit 1
fi

mkdir -p /etc/ssl/private /etc/ssl/certs

~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
  --key-file /etc/ssl/private/trojan.key \
  --fullchain-file /etc/ssl/certs/trojan.crt \
  --reloadcmd "systemctl restart trojan-go nginx"

# ========= 安装 Trojan-Go =========
echo -e "\n[4/7] 下载并安装 Trojan-Go..."
mkdir -p /etc/trojan-go
cd /etc/trojan-go || exit

LATEST=$(curl -s https://api.github.com/repos/p4gefau1t/trojan-go/releases/latest | grep browser_download_url | grep linux-amd64.zip | cut -d '"' -f 4)
curl -LO $LATEST
unzip -q *.zip && rm -f *.zip

# ========= 配置 Trojan-Go =========
echo -e "\n[5/7] 写入配置文件..."
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
    "enabled": true,
    "path": "/ws",
    "host": "$DOMAIN"
  },
  "router": {
    "enabled": true,
    "bypass": ["geoip:cn", "geosite:cn"],
    "block": ["geoip:private"]
  }
}
EOF

# ========= 配置 systemd 启动项 =========
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
systemctl restart trojan-go

# ========= 配置伪装页面 =========
echo -e "\n[6/7] 设置伪装站点..."
cat > /usr/share/nginx/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>站点维护中</title>
</head>
<body style="text-align:center;margin-top:10%">
  <h1>🚧 本站正在维护中 🚧</h1>
  <p>请稍后再访问</p>
</body>
</html>
EOF

systemctl enable nginx
systemctl restart nginx

# ========= 流量监控启动（vnstat） =========
systemctl enable vnstat
systemctl start vnstat

# ========= 完成提示 =========
echo -e "\n✅ 部署完成！以下是你的配置信息："
echo "--------------------------------------------"
echo "域名       ：$DOMAIN"
echo "Trojan 密码：$PASSWORD"
echo "端口       ：443"
echo "WebSocket 路径：/ws"
echo "伪装页面地址：http://$DOMAIN"
echo "Clash 可用：✅（需手动配置代理或托管）"
echo "--------------------------------------------"
