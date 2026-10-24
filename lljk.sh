#!/bin/sh

# 配置文件路径
CONFIG_FILE="/etc/lljk.conf"
LOG_FILE="/root/lljk.log"

# 获取当前脚本绝对路径
SCRIPT_PATH=$(readlink -f "$0")

# ---------------- 1. 自动检测并安装基础依赖 ----------------
check_and_install() {
    CMD=$1
    PKG=$2
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "未检测到 $CMD，正在自动安装..."
        if command -v apk >/dev/null 2>&1; then
            if [ "$PKG" = "cronie" ] && apk info -e dcron >/dev/null 2>&1; then
                echo "检测到冲突的 dcron，正在移除..."
                apk del dcron >/dev/null 2>&1 || true
            fi
            apk add --no-cache "$PKG"
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y "$PKG"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$PKG"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "$PKG"
        fi
    fi
}

# ---------------- 2. Telegram 消息推送函数 ----------------
send_tg_msg() {
    TEXT=$1
    if [ -n "$TG_BOT_TOKEN" ] && [ "$TG_BOT_TOKEN" != "无" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
             -d "chat_id=${TG_CHAT_ID}" \
             -d "text=${TEXT}" \
             -d "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi
}

# ---------------- 3. 交互式配置生成函数 ----------------
configure_interactive() {
    echo "=========================================="
    echo "       VPS 流量监控与报警 - 交互式配置"
    echo "=========================================="
    
    # 自动识别默认网卡
    DEFAULT_IF=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n 1)
    [ -z "$DEFAULT_IF" ] && DEFAULT_IF="eth0"
    
    printf "1. 请输入要监控的网卡接口 [默认: %s]: " "$DEFAULT_IF"
    read INPUT_IF
    INTERFACE=${INPUT_IF:-$DEFAULT_IF}

    printf "2. 请输入单向流量关机阈值 (GB) [默认: 180]: "
    read INPUT_MAX_GB
    MAX_GB=${INPUT_MAX_GB:-180}

    printf "3. 请输入 Telegram Bot Token (留空跳过): "
    read INPUT_TOKEN
    TG_BOT_TOKEN=${INPUT_TOKEN:-"无"}

    if [ "$TG_BOT_TOKEN" != "无" ]; then
        printf "4. 请输入 Telegram Chat ID: "
        read INPUT_CHAT_ID
        TG_CHAT_ID=${INPUT_CHAT_ID}
    else
        TG_CHAT_ID="无"
    fi

    # 保存配置到文件
    cat << EOF > "$CONFIG_FILE"
INTERFACE="${INTERFACE}"
MAX_GB="${MAX_GB}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EOF

    echo "------------------------------------------"
    echo "✅ 配置已成功保存至 ${CONFIG_FILE}！"
    
    # 发送 Telegram 测试消息
    if [ "$TG_BOT_TOKEN" != "无" ] && [ -n "$TG_CHAT_ID" ]; then
        echo "正在发送 Telegram 测试通知..."
        TEST_MSG="🎉 *VPS 流量监控脚本配置成功！*
⚙️ 监控网卡: \`${INTERFACE}\`
🚨 流量阈值: *${MAX_GB} GB*
🕒 当前时间: \`$(date "+%Y-%m-%d %H:%M:%S")\`"
        send_tg_msg "$TEST_MSG"
        echo "测试推送指令已发送，请检查 Telegram 账户接收情况！"
    fi
    echo "=========================================="
}

# ---------------- 4. 配置读取与初始化检查 ----------------
# 强制配置参数 (-c / --config) 或 首次运行无配置文件时触发交互
if [ "$1" = "-c" ] || [ "$1" = "--config" ] || [ ! -f "$CONFIG_FILE" ]; then
    configure_interactive
fi

# 载入配置
. "$CONFIG_FILE"

# ---------------- 5. 依赖安装与守护进程设置 ----------------
check_and_install "vnstat" "vnstat"
check_and_install "jq" "jq"
check_and_install "curl" "curl"
check_and_install "crond" "cronie"

if command -v rc-service >/dev/null 2>&1; then
    mkdir -p /var/lib/vnstat
    chown -R vnstat:vnstat /var/lib/vnstat 2>/dev/null || true
    rc-service vnstatd start >/dev/null 2>&1 || true
    rc-service cronie start >/dev/null 2>&1 || true
    rc-update add vnstatd default >/dev/null 2>&1 || true
    rc-update add cronie default >/dev/null 2>&1 || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl start vnstat >/dev/null 2>&1 || true
    systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1 || true
fi

# ---------------- 6. 自动添加定时任务 ----------------
CRON_5MIN="*/5 * * * * $SCRIPT_PATH >/dev/null 2>&1"
CRON_DAILY_12="0 12 * * * $SCRIPT_PATH send_tg >/dev/null 2>&1"

if ! crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then
    (crontab -l 2>/dev/null; echo "$CRON_5MIN"; echo "$CRON_DAILY_12") | crontab -
    echo "✅ 已自动配置定时任务：每 5 分钟流量检查，每日中午 12 点推送日报！"
fi

# ---------------- 7. 流量数据获取与统计 ----------------
TIME_NOW=$(date "+%Y-%m-%d %H:%M:%S")

# 获取 JSON 格式的月度流量
JSON_DATA=$(vnstat -i "$INTERFACE" --json m 1 2>/dev/null)

RX_BYTES=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].rx' 2>/dev/null)
TX_BYTES=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].tx' 2>/dev/null)

case "$RX_BYTES" in ''|'null'|*[!0-9]*) RX_BYTES=0 ;; esac
case "$TX_BYTES" in ''|'null'|*[!0-9]*) TX_BYTES=0 ;; esac

# 转换为 GB (保留两位小数)
RX_GB=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES / 1024 / 1024 / 1024}")
TX_GB=$(awk "BEGIN {printf \"%.2f\", $TX_BYTES / 1024 / 1024 / 1024}")

LOG_MSG="[$TIME_NOW] 网卡: ${INTERFACE} | 入站: ${RX_GB} GB | 出站: ${TX_GB} GB | 单向限额: ${MAX_GB} GB"
echo "$LOG_MSG" | tee -a "$LOG_FILE"

# 保留最近 200 行日志
tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"

# ---------------- 8. 功能逻辑控制 ----------------

# 手动发送/定时推送流量日报
if [ "$1" = "send_tg" ] || [ "$1" = "send" ]; then
    TG_TEXT="📊 *VPS 每日双向流量日报*
📅 时间: \`${TIME_NOW}\`
🌐 网卡: \`${INTERFACE}\`
📥 入站流量: *${RX_GB} GB* / *${MAX_GB} GB*
📤 出站流量: *${TX_GB} GB* / *${MAX_GB} GB*
⚙️ 状态: 正常监控中"
    send_tg_msg "$TG_TEXT"
    echo "推送指令已发送！"
    exit 0
fi

# 检查超限情况
RX_MB=$((RX_BYTES / 1024 / 1024))
TX_MB=$((TX_BYTES / 1024 / 1024))
MAX_MB=$((MAX_GB * 1024))

TRIGGER_SHUTDOWN=0
REASON=""

if [ "$RX_MB" -ge "$MAX_MB" ] && [ "$MAX_MB" -gt 0 ]; then
    TRIGGER_SHUTDOWN=1
    REASON="入站流量 (${RX_GB} GB) 已达限额 (${MAX_GB} GB)"
elif [ "$TX_MB" -ge "$MAX_MB" ] && [ "$MAX_MB" -gt 0 ]; then
    TRIGGER_SHUTDOWN=1
    REASON="出站流量 (${TX_GB} GB) 已达限额 (${MAX_GB} GB)"
fi

# 触发超限自动关机
if [ "$TRIGGER_SHUTDOWN" -eq 1 ]; then
    WARN_MSG="[$TIME_NOW] 警告：${REASON}，准备关机！"
    echo "$WARN_MSG" | tee -a "$LOG_FILE"
    
    TG_WARN_TEXT="⚠️ *VPS 流量超限关机预警*
🚨 原因: *${REASON}*
📥 当前入站: ${RX_GB} GB
📤 当前出站: ${TX_GB} GB
🛑 系统正在执行紧急关机保护！"
    send_tg_msg "$TG_WARN_TEXT"
    
    /sbin/poweroff
fi
