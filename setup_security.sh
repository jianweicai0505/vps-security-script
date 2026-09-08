#!/bin/sh

# 设置发生错误时立即停止
set -e

NEW_SSH_PORT=53678

echo "=== 0. 自动识别操作系统类型 ==="
OS_TYPE="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

echo "检测到系统类型: ${OS_TYPE}"

# 封装包安装与服务管理函数
pkg_install() {
    case "$OS_TYPE" in
        alpine)
            apk update && apk add --no-cache "$@"
            ;;
        debian|ubuntu)
            apt-get update && apt-get install -y "$@"
            ;;
        centos|rhel|rocky|almalinux)
            dnf install -y "$@" || yum install -y "$@"
            ;;
        *)
            echo "未识别的操作系统，请手动安装包: $@"
            exit 1
            ;;
    esac
}

svc_enable_start() {
    SERVICE=$1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable "$SERVICE"
        systemctl restart "$SERVICE"
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add "$SERVICE" default || true
        rc-service "$SERVICE" restart || rc-service "$SERVICE" start
    fi
}

echo "=== 1. 检查并安装必要服务 ==="
case "$OS_TYPE" in
    alpine)
        pkg_install iptables fail2ban openrc openssh
        ;;
    debian|ubuntu)
        # 卸载可能冲突的 ufw
        if command -v ufw >/dev/null 2>&1 || dpkg -l | grep -q ufw; then
            echo "正在卸载 ufw 以防止冲突..."
            ufw disable 2>/dev/null || true
            apt-get remove -y --purge ufw 2>/dev/null || true
        fi
        pkg_install iptables iptables-persistent fail2ban
        svc_enable_start netfilter-persistent
        ;;
    *)
        pkg_install iptables iptables-services fail2ban
        svc_enable_start iptables
        ;;
esac

echo "=== 2. 清空原有 iptables 规则 ==="
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F              # 清空所有链规则
iptables -X              # 删除所有自定义链
iptables -Z              # 清零所有计数器

echo "=== 3. 修改系统 SSH 端口为 ${NEW_SSH_PORT} ==="
if [ -f /etc/ssh/sshd_config ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    if grep -qE "^#?Port " /etc/ssh/sshd_config; then
        sed -i -E "s/^#?Port .*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
    else
        echo "Port ${NEW_SSH_PORT}" >> /etc/ssh/sshd_config
    fi
    echo "SSH 配置文件已更新，端口设为: ${NEW_SSH_PORT}"
fi

echo "=== 4. 配置全新 iptables 防火墙规则 ==="
# 1. 保证已建立连接的通信不中断（防切断当前连接）
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# 2. 本地环回接口放行
iptables -A INPUT -i lo -j ACCEPT

# 3. ICMP 速率限制 (1/s, burst 4)
iptables -A INPUT -p icmp --icmp-type echo-request -m hashlimit --hashlimit-name ICMP --hashlimit-mode srcip --hashlimit-upto 1/sec --hashlimit-burst 4 -j ACCEPT

# --- 4. 专属白名单端口放行区域 ---
iptables -A INPUT -p tcp --dport ${NEW_SSH_PORT} -j ACCEPT  # 修改后的 SSH 端口
iptables -A INPUT -p tcp --dport 443 -j ACCEPT             # HTTPS 443
iptables -A INPUT -p tcp --dport 49880 -j ACCEPT           # 49880 TCP
iptables -A INPUT -p tcp --dport 50021:50030 -j ACCEPT     # 端口段 TCP
iptables -A INPUT -p udp --dport 50021:50030 -j ACCEPT     # 端口段 UDP

# 5. 末尾兜底拦截（除上述白名单外拒绝所有）
iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited

echo "=== 5. 持久化保存 iptables 规则 ==="
if [ "$OS_TYPE" = "alpine" ]; then
    rc-service iptables save 2>/dev/null || /etc/init.d/iptables save
    svc_enable_start iptables
elif command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
else
    service iptables save 2>/dev/null || true
fi

echo "=== 6. 配置 Fail2ban ==="
mkdir -p /etc/fail2ban/jail.d

# 根据系统确定日志路径
LOG_PATH="%(sshd_log)s"
if [ "$OS_TYPE" = "alpine" ]; then
    LOG_PATH="/var/log/messages"
fi

cat << FAIL2BAN_EOF > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled  = true
port     = ${NEW_SSH_PORT}
logpath  = ${LOG_PATH}
maxretry = 3
findtime = 600
bantime  = 3600
FAIL2BAN_EOF

svc_enable_start fail2ban

echo "=== 7. 重启 SSH 服务 ==="
if [ "$OS_TYPE" = "alpine" ]; then
    rc-service sshd restart
elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh || systemctl restart sshd
fi

echo "=================================================================="
echo "  ✅ 系统加固完成！当前系统类型: ${OS_TYPE}"
echo "  放行端口列表：${NEW_SSH_PORT}(SSH), 443(TCP), 49880(TCP), 50021:50030(TCP/UDP)"
echo "  注意：当前终端连接不会断开，请开一个新窗口测试 SSH 连接："
echo "  ssh -p ${NEW_SSH_PORT} root@<你的IP>"
echo "=================================================================="
