cat << 'EOF' > /root/setup_security.sh
#!/bin/bash

# 设置发生错误时立即停止
set -e

echo "=== 1. 检查并开启 iptables 与 fail2ban 服务 ==="
# 更新软件源并安装必要组件
apt-get update
apt-get install -y iptables iptables-persistent fail2ban

# 确保 iptables-persistent 服务已开机自启
systemctl enable netfilter-persistent
systemctl start netfilter-persistent

echo "=== 2. 配置 iptables 防火墙规则 ==="

# 封装函数：检测端口是否存在，不存在则精准插入到 REJECT 前或追加到末尾
add_iptables_rule() {
    local proto=$1
    local dport=$2

    # 检查规则是否已存在
    if iptables -C INPUT -p "$proto" --dport "$dport" -j ACCEPT 2>/dev/null; then
        echo "规则已存在: $proto $dport，跳过添加。"
    else
        # 动态查找 REJECT 规则所在的行号
        REJECT_LINE=$(iptables -L INPUT --line-numbers -n | grep "REJECT" | awk '{print $1}' | head -n 1)

        if [ -n "$REJECT_LINE" ]; then
            # 如果存在 REJECT 规则，插入到该行之前
            iptables -I INPUT "$REJECT_LINE" -p "$proto" --dport "$dport" -j ACCEPT
            echo "成功插入规则 (REJECT 之前): $proto $dport"
        else
            # 如果不存在 REJECT，直接追加到末尾
            iptables -A INPUT -p "$proto" --dport "$dport" -j ACCEPT
            echo "成功追加规则: $proto $dport"
        fi
    fi
}

# --- 开始依次添加放行端口 ---
# 1. 放行 22 (SSH TCP)
add_iptables_rule tcp 22

# 2. 放行 443 (HTTPS TCP)
add_iptables_rule tcp 443

# 3. 放行 2096 (TCP & UDP)
add_iptables_rule tcp 2096
add_iptables_rule udp 2096

# 4. 放行 50021:50030 (TCP & UDP)
add_iptables_rule tcp 50021:50030
add_iptables_rule udp 50021:50030

echo "=== 3. 持久化保存 iptables 规则 ==="
netfilter-persistent save || service iptables save

echo "=== 4. 配置 Fail2ban SSH 防爆破 ==="

# 备份默认配置并生成 jail.local
if [ ! -f /etc/fail2ban/jail.local ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# 写入 SSH 防爆破规则 (3次输错密码封禁 1 小时)
cat << 'JAILEOF' > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
findtime = 600
bantime  = 3600
JAILEOF

# 启动并开机自启 fail2ban
systemctl enable fail2ban
systemctl restart fail2ban

echo "=========================================="
echo "      ✅ 所有安全与端口规则已全部整合完成！"
echo "=========================================="
EOF

# 赋予执行权限并直接运行
chmod +x /root/setup_security.sh
/root/setup_security.sh