# Trojan-Go 一键部署脚本

这是一个用于在 Linux VPS 上快速部署 Trojan-Go + TLS + Nginx 伪装站点的 Shell 脚本，适用于 **CentOS / RHEL / Rocky / AlmaLinux** 系统。

## ✨ 特性介绍

- 自动安装 Trojan-Go 最新版本
- 自动签发 HTTPS 证书（使用 acme.sh）
- 支持 TLS 加密
- 可选 Nginx 伪装站点（维护页）
- 配置 systemd 自启动服务
- 防火墙自动开放 443/80 端口
- 简单交互式配置（输入域名、密码即可）

## 🧾 使用说明

### 1. 系统要求

- 推荐系统：CentOS 7+ / Rocky Linux 8+ / AlmaLinux 8+
- 必须拥有一个已解析到该 VPS 的域名
- 安装前请确保系统未占用 80/443 端口（如已有 nginx 可先停止）

### 2. 获取脚本

```bash
wget https://your-server-or-github/trojan_deploy.sh
chmod +x trojan_deploy.sh
```

### 3. 执行脚本

```bash
./trojan_deploy.sh
```
按照提示输入：

1.你的域名（必须已解析到 VPS）
2.Trojan 密码（自定义）

脚本会自动完成安装配置，启动 Trojan-Go 并部署伪装站点。

📌 默认配置信息
| 配置项 | 值 |
|--------|-----|
| Trojan-Go 端口 | 443 |
| 配置路径 | /etc/trojan-go/config.json |
| 证书路径 | /etc/ssl/ |
| 伪装网页目录 | /usr/share/nginx/html/ |

🧠 注意事项
请确保你的域名已正确解析到 VPS IP
若使用 Cloudflare，建议将代理（橙云）关闭以便证书签发
安装过程中会尝试自动申请证书，可能需要临时关闭防火墙占用的服务

🧰 其他推荐
可结合 DNS 解污染、流媒体解锁规则使用
配合 Clash / Clash Verge 使用，自定义配置订阅
如需支持 WebSocket、Hysteria 等，需手动拓展配置
