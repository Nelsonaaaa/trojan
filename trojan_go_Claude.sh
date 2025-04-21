#!/bin/bash

#########################################################################
# Trojan-Go 自动部署脚本                                                 #
# 作者: Claude                                                          #
# 日期: 2025-04-21                                                      #
# 描述: 自动化部署 Trojan-Go 服务器，包括申请 SSL 证书、安装和配置        #
#       Trojan-Go、设置伪装网站等                                        #
# 执行脚本（需指定域名） ./trojan-go-install.sh --domain your-domain.com
# 执行脚本（域名+自定义密码）./trojan-go-install.sh --domain your-domain.com --password your-password
#########################################################################

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 日志文件
LOG_FILE="/var/log/trojan-go-install.log"

# 版本信息
VERSION="1.0.0"
TROJAN_GO_VERSION="v0.10.6" # 根据最新版本更新 [[2]](#__2)

# 全局变量
DOMAIN=""
PASSWORD=""
WEB_PATH="/var/www/html"
TROJAN_GO_PATH="/usr/local/bin/trojan-go"
CONFIG_PATH="/etc/trojan-go"

# 日志函数
log() {
    echo -e "$1" | tee -a ${LOG_FILE}
}

info() {
    log "${GREEN}[信息]${PLAIN} $1"
}

warning() {
    log "${YELLOW}[警告]${PLAIN} $1"
}

error() {
    log "${RED}[错误]${PLAIN} $1"
}

success() {
    log "${BLUE}[成功]${PLAIN} $1"
}

# 检查是否为 Root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 用户身份运行"
        exit 1
    fi
}

# 检查系统类型
check_system() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    else
        error "不支持的操作系统"
        exit 1
    fi
    
    # 检查系统位数
    if [[ $(uname -m) != "x86_64" ]]; then
        error "系统架构不是 x86_64，不支持安装"
        exit 1
    fi
    
    info "检测到系统为 ${OS}"
}

# 显示帮助信息
show_help() {
    echo "Trojan-Go 自动部署脚本 ${VERSION}"
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help                显示此帮助信息"
    echo "  -d, --domain <域名>       指定域名 (必须)"
    echo "  -p, --password <密码>     指定 Trojan-Go 密码 (可选，默认随机生成)"
    echo "  -v, --version             显示版本信息"
    echo ""
    echo "示例:"
    echo "  $0 --domain example.com --password your_password"
    echo "  $0 --domain example.com"
    echo ""
}

# 显示版本信息
show_version() {
    echo "Trojan-Go 自动部署脚本 ${VERSION}"
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD="$2"
                shift 2
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            *)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 验证必要参数
    if [[ -z "${DOMAIN}" ]]; then
        error "必须指定域名"
        show_help
        exit 1
    fi
    
    # 如果未指定密码，则生成随机密码
    if [[ -z "${PASSWORD}" ]]; then
        PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
        info "已生成随机密码: ${PASSWORD}"
    fi
}

# 更新系统
update_system() {
    info "更新系统中..."
    
    if [[ "${OS}" == "debian" ]]; then
        apt-get update -y > /dev/null 2>&1
        apt-get upgrade -y > /dev/null 2>&1
    else
        yum update -y > /dev/null 2>&1
    fi
    
    success "系统更新完成"
}

# 安装依赖
install_dependencies() {
    info "安装依赖中..."
    
    if [[ "${OS}" == "debian" ]]; then
        apt-get install -y curl wget unzip jq net-tools socat cron > /dev/null 2>&1
    else
        yum install -y curl wget unzip jq net-tools socat cronie > /dev/null 2>&1
    fi
    
    success "依赖安装完成"
}

# 安装 Nginx
install_nginx() {
    info "安装 Nginx 中..."
    
    if [[ "${OS}" == "debian" ]]; then
        apt-get install -y nginx > /dev/null 2>&1
        systemctl enable nginx > /dev/null 2>&1
        systemctl start nginx > /dev/null 2>&1
    else
        yum install -y nginx > /dev/null 2>&1
        systemctl enable nginx > /dev/null 2>&1
        systemctl start nginx > /dev/null 2>&1
    fi
    
    success "Nginx 安装完成"
}

# 配置防火墙
configure_firewall() {
    info "配置防火墙中..."
    
    if [[ "${OS}" == "debian" ]]; then
        apt-get install -y ufw > /dev/null 2>&1
        ufw allow ssh > /dev/null 2>&1
        ufw allow 80/tcp > /dev/null 2>&1
        ufw allow 443/tcp > /dev/null 2>&1
        echo "y" | ufw enable > /dev/null 2>&1
    else
        yum install -y firewalld > /dev/null 2>&1
        systemctl start firewalld > /dev/null 2>&1
        systemctl enable firewalld > /dev/null 2>&1
        firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
        firewall-cmd --permanent --add-port=80/tcp > /dev/null 2>&1
        firewall-cmd --permanent --add-port=443/tcp > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1
    fi
    
    success "防火墙配置完成"
}

# 检查域名解析
check_domain() {
    info "检查域名 ${DOMAIN} 解析中..."
    
    # 获取域名解析的 IP
    domain_ip=$(ping -c 1 -t 1 ${DOMAIN} 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [[ -z "${domain_ip}" ]]; then
        error "域名 ${DOMAIN} 解析失败，请检查 DNS 设置"
        exit 1
    fi
    
    # 获取本机 IP
    local_ip=$(curl -s https://api.ipify.org)
    if [[ -z "${local_ip}" ]]; then
        error "获取本机 IP 失败"
        exit 1
    fi
    
    # 比较域名解析的 IP 和本机 IP
    if [[ "${domain_ip}" != "${local_ip}" ]]; then
        error "域名 ${DOMAIN} 解析的 IP (${domain_ip}) 与本机 IP (${local_ip}) 不匹配"
        error "请确保域名正确解析到本机 IP 后再运行此脚本"
        exit 1
    fi
    
    success "域名 ${DOMAIN} 解析正确"
}

# 申请 SSL 证书
apply_ssl_cert() {
    info "申请 SSL 证书中..."
    
    # 安装 acme.sh
    curl https://get.acme.sh | sh > /dev/null 2>&1
    
    # 设置 acme.sh 自动更新
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    
    # 停止 Nginx
    systemctl stop nginx > /dev/null 2>&1
    
    # 申请证书
    ~/.acme.sh/acme.sh --issue --standalone -d ${DOMAIN} -k ec-256 > /dev/null 2>&1
    
    if [[ $? -ne 0 ]]; then
        error "SSL 证书申请失败"
        exit 1
    fi
    
    # 创建证书目录
    mkdir -p ${CONFIG_PATH}
    
    # 安装证书
    ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} --ecc \
        --key-file ${CONFIG_PATH}/server.key \
        --fullchain-file ${CONFIG_PATH}/server.crt > /dev/null 2>&1
    
    chmod 644 ${CONFIG_PATH}/server.crt
    chmod 600 ${CONFIG_PATH}/server.key
    
    # 重启 Nginx
    systemctl start nginx > /dev/null 2>&1
    
    success "SSL 证书申请成功"
}

# 创建自动续期脚本
create_renew_script() {
    info "创建证书自动续期脚本..."
    
    mkdir -p /etc/letsencrypt/renewal-hooks/post/
    
    cat > /etc/letsencrypt/renewal-hooks/post/trojan-go-renew.sh << EOF
#!/bin/bash
cp ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer ${CONFIG_PATH}/server.crt
cp ~/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key ${CONFIG_PATH}/server.key
chmod 644 ${CONFIG_PATH}/server.crt
chmod 600 ${CONFIG_PATH}/server.key
systemctl restart trojan-go
EOF
    
    chmod +x /etc/letsencrypt/renewal-hooks/post/trojan-go-renew.sh
    
    success "证书自动续期脚本创建完成"
}

# 安装 Trojan-Go
install_trojan_go() {
    info "安装 Trojan-Go 中..."
    
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd ${TMP_DIR}
    
    # 下载 Trojan-Go
    wget -q https://github.com/p4gefau1t/trojan-go/releases/download/${TROJAN_GO_VERSION}/trojan-go-linux-amd64.zip
    
    if [[ $? -ne 0 ]]; then
        error "Trojan-Go 下载失败"
        rm -rf ${TMP_DIR}
        exit 1
    fi
    
    # 解压
    unzip -q trojan-go-linux-amd64.zip
    
    # 创建目录
    mkdir -p ${TROJAN_GO_PATH}
    
    # 复制文件
    cp trojan-go ${TROJAN_GO_PATH}/
    chmod +x ${TROJAN_GO_PATH}/trojan-go
    
    # 清理临时文件
    cd - > /dev/null
    rm -rf ${TMP_DIR}
    
    success "Trojan-Go 安装完成"
}

# 配置 Trojan-Go
configure_trojan_go() {
    info "配置 Trojan-Go 中..."
    
    # 创建配置目录
    mkdir -p ${CONFIG_PATH}
    
    # 创建配置文件
    cat > ${CONFIG_PATH}/config.json << EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "${PASSWORD}"
    ],
    "ssl": {
        "cert": "${CONFIG_PATH}/server.crt",
        "key": "${CONFIG_PATH}/server.key",
        "sni": "${DOMAIN}",
        "fallback_addr": "127.0.0.1",
        "fallback_port": 80
    },
    "tcp": {
        "prefer_ipv4": true,
        "no_delay": true,
        "keep_alive": true,
        "reuse_port": true,
        "fast_open": false,
        "fast_open_qlen": 20
    },
    "websocket": {
        "enabled": false,
        "path": "/trojan-ws",
        "host": "${DOMAIN}"
    },
    "router": {
        "enabled": true,
        "block": [
            "geoip:private"
        ]
    }
}
EOF
    
    success "Trojan-Go 配置完成"
}

# 创建系统服务
create_service() {
    info "创建 Trojan-Go 系统服务中..."
    
    cat > /etc/systemd/system/trojan-go.service << EOF
[Unit]
Description=Trojan-Go - An unidentifiable mechanism that helps you bypass GFW
Documentation=https://p4gefau1t.github.io/trojan-go/
After=network.target nss-lookup.target

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${TROJAN_GO_PATH}/trojan-go -config ${CONFIG_PATH}/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    # 启动服务
    systemctl start trojan-go
    systemctl enable trojan-go > /dev/null 2>&1
    
    success "Trojan-Go 系统服务创建完成"
}

# 配置伪装网站
configure_web() {
    info "配置伪装网站中..."
    
    # 创建 Nginx 配置
    cat > /etc/nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    
    location / {
        root ${WEB_PATH};
        index index.html index.htm;
    }
}
EOF
    
    # 创建简单的伪装网站
    cat > ${WEB_PATH}/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 40px;
            line-height: 1.6;
        }
        h1 {
            color: #333;
        }
    </style>
</head>
<body>
    <h1>Welcome to my website!</h1>
    <p>This is a sample page.</p>
</body>
</html>
EOF
    
    # 重启 Nginx
    systemctl restart nginx
    
    success "伪装网站配置完成"
}

# 检查服务状态
check_status() {
    info "检查服务状态中..."
    
    # 检查 Trojan-Go 是否运行
    if systemctl is-active --quiet trojan-go; then
        success "Trojan-Go 服务运行正常"
    else
        error "Trojan-Go 服务未运行，请检查日志"
        journalctl -u trojan-go -n 20
        exit 1
    fi
    
    # 检查 Nginx 是否运行
    if systemctl is-active --quiet nginx; then
        success "Nginx 服务运行正常"
    else
        error "Nginx 服务未运行，请检查日志"
        exit 1
    fi
    
    # 检查端口是否被占用
    if netstat -tuln | grep -q ":443 "; then
        success "443 端口已被 Trojan-Go 占用"
    else
        error "443 端口未被占用，Trojan-Go 可能未正常运行"
        exit 1
    fi
}

# 显示客户端配置
show_client_config() {
    echo ""
    echo "=========================================================="
    echo -e "${GREEN}Trojan-Go 安装成功！${PLAIN}"
    echo "=========================================================="
    echo -e "域名: ${BLUE}${DOMAIN}${PLAIN}"
    echo -e "密码: ${BLUE}${PASSWORD}${PLAIN}"
    echo -e "端口: ${BLUE}443${PLAIN}"
    echo ""
    echo -e "客户端配置示例:"
    echo ""
    echo -e "${GREEN}---开始---${PLAIN}"
    echo "{
    \"run_type\": \"client\",
    \"local_addr\": \"127.0.0.1\",
    \"local_port\": 1080,
    \"remote_addr\": \"${DOMAIN}\",
    \"remote_port\": 443,
    \"password\": [
        \"${PASSWORD}\"
    ],
    \"ssl\": {
        \"sni\": \"${DOMAIN}\"
    },
    \"mux\": {
        \"enabled\": true,
        \"concurrency\": 8,
        \"idle_timeout\": 60
    }
}"
    echo -e "${GREEN}---结束---${PLAIN}"
    echo ""
    echo "将以上配置保存为 config.json，然后使用客户端版本的 Trojan-Go 运行即可。"
    echo "=========================================================="
}

# 主函数
main() {
    clear
    echo "=========================================================="
    echo "Trojan-Go 自动部署脚本 ${VERSION}"
    echo "=========================================================="
    echo ""
    
    # 初始化日志文件
    echo "# Trojan-Go 安装日志 - $(date)" > ${LOG_FILE}
    
    # 检查 Root 权限
    check_root
    
    # 检查系统类型
    check_system
    
    # 解析命令行参数
    parse_args "$@"
    
    # 更新系统
    update_system
    
    # 安装依赖
    install_dependencies
    
    # 安装 Nginx
    install_nginx
    
    # 配置防火墙
    configure_firewall
    
    # 检查域名解析
    check_domain
    
    # 申请 SSL 证书
    apply_ssl_cert
    
    # 创建自动续期脚本
    create_renew_script
    
    # 安装 Trojan-Go
    install_trojan_go
    
    # 配置 Trojan-Go
    configure_trojan_go
    
    # 创建系统服务
    create_service
    
    # 配置伪装网站
    configure_web
    
    # 检查服务状态
    check_status
    
    # 显示客户端配置
    show_client_config
}

# 执行主函数
main "$@"
