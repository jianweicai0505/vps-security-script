Bash
cat << 'EOF' > /root/setup_security.sh
#!/bin/bash

# 设置发生错误时论及停止
set -e

echo "=== 1. 检查并开启 iptables 与 fail2ban 服务 ==="
apt-get update
apt-get install -y iptables iptables-persistent fail2ban

systemctl enable netfilter-persistent
systemctl start netfilter-persistent

echo "=== 2. 配置 iptables 防火墙规则 ==="

# 封装函数：确保放行规则插入在兜底 REJECT 之前，避免被拦截
add_iptables_rule() {
    local proto=$1
    local dport=$2

    if iptables -C INPUT -p "$proto" --dport "$dport" -j ACCEPT 2>/dev/null; then
        echo "规则已存在: $proto $dport，跳过添加。"
    else
        REJECT_LINE=$(iptables -L INPUT --line-numbers -n | grep "REJECT" | awk '{print $1}' | head -n 1)

        if [ -n "$REJECT_LINE" ]; then
            iptables -I INPUT "$REJECT_LINE" -p "$proto" --dport "$dport" -j ACCEPT
            echo "成功插入规则 (REJECT 之前): $proto $dport"
        else
            iptables -A INPUT -p "$proto" --dport "$dport" -j ACCEPT
            echo "成功追加规则: $proto $dport"
        fi
    fi
}

# --- 白名单端口放行区域 ---
add_iptables_rule tcp 22          # SSH
add_iptables_rule tcp 443         # HTTPS
add_iptables_rule tcp 2096        # 自定义 TCP
add_iptables_rule udp 2096        # 自定义 UDP
add_iptables_rule tcp 49880       # 新增 49880 TCP
add_iptables_rule tcp 50021:50030 # 端口段 TCP
add_iptables_rule udp 50021:50030 # 端口段 UDP

# 保持已建立相关连接的通信（保证已建立的连接不中断）
if ! iptables -C INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# --- 配置末尾兜底拦截规则（拒绝其他所有未放行端口）---
if ! iptables -L INPUT -n | grep -q "reject-with icmp-host-prohibited"; then
    iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited
    echo "成功设置末尾兜底拦截规则 (REJECT All)"
fi

echo "=== 3. 持久化保存 iptables 规则 ==="
netfilter-persistent save || service iptables save

echo "=== 4. 配置 Fail2ban SSH 防爆破 ==="

if [ ! -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# 写入 SSH 防爆破配置
echo '[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
findtime = 600
bantime  = 3600' > /etc/fail2ban/jail.d/sshd.local

systemctl enable fail2ban
systemctl restart fail2ban

echo "=========================================="
echo "      ✅ 默认拒绝策略与端口白名单已配置完成！"
echo "=========================================="
EOF
