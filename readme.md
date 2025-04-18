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
