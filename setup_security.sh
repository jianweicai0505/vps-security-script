#!/bin/bash

# 设置发生错误时立即停止
set -e

NEW_SSH_PORT=53678

echo "=== 1. 检查并安装必要服务 ==="
apt-get update
apt-get install -y iptables iptables-persistent fail2ban ufw

systemctl enable netfilter-persistent

echo "=== 2. 清空原有的 ufw 与 iptables 规则 ==="

# 2.1 禁用并重置 ufw 防火墙（如果已安装/启用）
if command -v ufw >/dev/null 2>&1; then
    echo "正在重置并禁用 ufw..."
    ufw --force reset || true
    ufw disable || true
fi

# 2.2 清空 iptables 所有链中的规则并重置默认策略
echo "正在清空 iptables 现有规则..."
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F              # 清空所有链规则
iptables -X              # 删除所有自定义链
iptables -Z              # 清零所有计数器

echo "=== 3. 修改系统 SSH 端口为 ${NEW_SSH_PORT} ==="
if [ -f /etc/ssh/sshd_config ]; then
    # 备份原始文件
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    
    # 替换或取消注释 Port 属性
    if grep -qE "^#?Port " /etc/ssh/sshd_config; then
        sed -i -E "s/^#?Port .*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
    else
        echo "Port ${NEW_SSH_PORT}" >> /etc/ssh/sshd_config
    fi
    echo "SSH 配置文件已更新，端口设为: ${NEW_SSH_PORT}"
fi

echo "=== 4. 配置全新 iptables 防火墙规则 ==="

# 1. 优先保证已建立连接的通信不中断（放在第 1 行）
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# 2. 部署 ICMP 速率限制（针对单个源 IP：每秒最多 1 个，突发允许 4 个，超出部分将掉入末尾 REJECT）
iptables -A INPUT -p icmp --icmp-type echo-request -m hashlimit --hashlimit-name ICMP --hashlimit-mode srcip --hashlimit-upto 1/sec --hashlimit-burst 4 -j ACCEPT
echo "成功增加 ICMP 限速放行规则 (1 req/s, burst 4)"

# --- 3. 针对 2096 和 8443 端口部署频率限制（1小时最多访问 3 次） ---
# TCP 2096
iptables -A INPUT -p tcp --dport 2096 -m state --state NEW -m recent --set --name LIMIT_2096_TCP
iptables -A INPUT -p tcp --dport 2096 -m state --state NEW -m recent --update --seconds 3600 --hitcount 4 --name LIMIT_2096_TCP -j DROP
iptables -A INPUT -p tcp --dport 2096 -j ACCEPT

# UDP 2096
iptables -A INPUT -p udp --dport 2096 -m recent --set --name LIMIT_2096_UDP
iptables -A INPUT -p udp --dport 2096 -m recent --update --seconds 3600 --hitcount 4 --name LIMIT_2096_UDP -j DROP
iptables -A INPUT -p udp --dport 2096 -j ACCEPT

# TCP 8443
iptables -A INPUT -p tcp --dport 8443 -m state --state NEW -m recent --set --name LIMIT_8443_TCP
iptables -A INPUT -p tcp --dport 8443 -m state --state NEW -m recent --update --seconds 3600 --hitcount 4 --name LIMIT_8443_TCP -j DROP
iptables -A INPUT -p tcp --dport 8443 -j ACCEPT

# UDP 8443
iptables -A INPUT -p udp --dport 8443 -m recent --set --name LIMIT_8443_UDP
iptables -A INPUT -p udp --dport 8443 -m recent --update --seconds 3600 --hitcount 4 --name LIMIT_8443_UDP -j DROP
iptables -A INPUT -p udp --dport 8443 -j ACCEPT

echo "成功为 2096 与 8443 端口（TCP/UDP）添加频率限制：单个 IP 1 小时内最多 3 次"

# --- 4. 普通白名单端口放行区域 ---
iptables -A INPUT -p tcp --dport ${NEW_SSH_PORT} -j ACCEPT  # 修改后的 SSH 端口
echo "成功放行 SSH 端口: ${NEW_SSH_PORT}"

iptables -A INPUT -p tcp --dport 443 -j ACCEPT             # HTTPS
iptables -A INPUT -p tcp --dport 49880 -j ACCEPT           # 49880 TCP
iptables -A INPUT -p tcp --dport 50021:50030 -j ACCEPT     # 端口段 TCP
iptables -A INPUT -p udp --dport 50021:50030 -j ACCEPT     # 端口段 UDP

# --- 5. 设置末尾兜底拦截规则 ---
iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited
echo "成功设置末尾兜底拦截规则 (REJECT All)"

echo "=== 5. 持久化保存 iptables 规则 ==="
netfilter-persistent save || service iptables save

echo "=== 6. 配置 Fail2ban (绑定 SSH 新端口 ${NEW_SSH_PORT}) ==="
if [ ! -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# 写入 SSH 防爆破配置（显式指定新端口）
cat << FAIL2BAN_EOF > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled  = true
port     = ${NEW_SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
findtime = 600
bantime  = 3600
FAIL2BAN_EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "=== 7. 重启 SSH 服务以使新端口生效 ==="
systemctl restart ssh || systemctl restart sshd

echo "=================================================================="
echo "  ✅ 防火墙重置与最新限速/限频规则配置完成！"
echo "  注意：当前终端连接不会断开，但请另外开一个窗口验证 SSH 登录："
echo "  ssh -p ${NEW_SSH_PORT} root@<你的IP>"
echo "=================================================================="
