#!/bin/sh

# ---------------- 参数配置 ----------------
INTERFACE="eth0"
MAX_GB=180             # 单向流量阈值 (入站或出站任意达到 180GB 即关机)
LOG_FILE="/root/lljk.log"

# Telegram 机器人配置
TG_BOT_TOKEN="你的_BOT_TOKEN"
TG_CHAT_ID="你的_CHAT_ID"
# ------------------------------------------

# 获取当前脚本的绝对路径
SCRIPT_PATH=$(readlink -f "$0")

# ---------------- 1. 自动检测并安装依赖 ----------------
check_and_install() {
    CMD=$1
    PKG=$2
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "未检测到 $CMD，正在自动安装..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache "$PKG" openrc cronie curl
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y "$PKG" cron curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$PKG" cronie curl
        fi
    fi
}

check_and_install "vnstat" "vnstat"
check_and_install "jq" "jq"
check_and_install "curl" "curl"

# 启动后台服务
if command -v rc-service >/dev/null 2>&1; then
    rc-service vnstat start >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
    rc-update add crond default >/dev/null 2>&1 || true
elif command -v systemctl >/dev/null 2>&1; then
    systemctl start vnstat >/dev/null 2>&1 || true
    systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1 || true
fi

# ---------------- 2. 自动配置定时任务 ----------------
CRON_5MIN="*/5 * * * * $SCRIPT_PATH >/dev/null 2>&1"
CRON_DAILY_12="0 12 * * * $SCRIPT_PATH send_tg >/dev/null 2>&1"

if ! crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then
    (crontab -l 2>/dev/null; echo "$CRON_5MIN"; echo "$CRON_DAILY_12") | crontab -
    echo "✅ 已成功配置定时任务：每 5 分钟双向流量监控，每天中午 12 点 TG 推送！"
fi

# ---------------- 3. Telegram 推送函数 ----------------
send_tg_msg() {
    TEXT=$1
    if [ -n "$TG_BOT_TOKEN" ] && [ "$TG_BOT_TOKEN" != "你的_BOT_TOKEN" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
             -d "chat_id=${TG_CHAT_ID}" \
             -d "text=${TEXT}" \
             -d "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi
}

# ---------------- 4. 流量统计与双向提取 ----------------
TIME_NOW=$(date "+%Y-%m-%d %H:%M:%S")

# 获取 JSON 数据
JSON_DATA=$(vnstat -i "$INTERFACE" --json m 1)

# 分别提取入站 (rx) 和出站 (tx) 字节数
RX_BYTES=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].rx // 0')
TX_BYTES=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].tx // 0')

if [ "$RX_BYTES" = "null" ] || [ -z "$RX_BYTES" ]; then RX_BYTES=0; fi
if [ "$TX_BYTES" = "null" ] || [ -z "$TX_BYTES" ]; then TX_BYTES=0; fi

# 分别计算入站与出站 GB (保留两位小数)
RX_GB=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES / 1024 / 1024 / 1024}")
TX_GB=$(awk "BEGIN {printf \"%.2f\", $TX_BYTES / 1024 / 1024 / 1024}")

# 格式化控制台与日志输出
LOG_MSG="[$TIME_NOW] 入站: ${RX_GB} GB | 出站: ${TX_GB} GB | 单向限额: ${MAX_GB} GB"
echo "$LOG_MSG" | tee -a "$LOG_FILE"

# 日志清理 (保留最新200行)
tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"

# ---------------- 5. 逻辑分支判断 ----------------

# A. 每日中午 12 点发送电报日报
if [ "$1" = "send_tg" ]; then
    TG_TEXT="📊 *VPS 每日双向流量日报*
📅 时间: \`${TIME_NOW}\`
📥 入站流量: *${RX_GB} GB* / *${MAX_GB} GB*
📤 出站流量: *${TX_GB} GB* / *${MAX_GB} GB*
⚙️ 状态: 正常监控中"
    send_tg_msg "$TG_TEXT"
    exit 0
fi

# B. 双向超限判定 (换算成 MB 进行比较)
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

# C. 触发关机
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
