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

# ---------------- 1. 自动检测并安装依赖 (适配 Alpine 特性) ----------------
check_and_install() {
    CMD=$1
    PKG=$2
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "未检测到 $CMD，正在自动安装..."
        if command -v apk >/dev/null 2>&1; then
            # 解决 Alpine 下 dcron 与 cronie 的包冲突
            if [ "$PKG" = "cronie" ] && apk info -e dcron >/dev/null 2>&1; then
                echo "检测到冲突的 dcron，正在移除..."
                apk del dcron >/dev/null 2>&1 || true
            fi
            apk add --no-cache "$PKG"
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y "$PKG"
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "$PKG"
        fi
    fi
}

# 安装基础依赖
check_and_install "vnstat" "vnstat"
check_and_install "jq" "jq"
check_and_install "curl" "curl"
check_and_install "crond" "cronie"

# ---------------- 2. 守护进程与数据库自动初始化 ----------------
if command -v rc-service >/dev/null 2>&1; then
    # Alpine OpenRC 环境
    mkdir -p /var/lib/vnstat
    chown -R vnstat:vnstat /var/lib/vnstat 2>/dev/null || true
    
    rc-service vnstatd start >/dev/null 2>&1 || true
    rc-service cronie start >/dev/null 2>&1 || true
    rc-update add vnstatd default >/dev/null 2>&1 || true
    rc-update add cronie default >/dev/null 2>&1 || true
elif command -v systemctl >/dev/null 2>&1; then
    # Systemd 环境 (Debian/Ubuntu/CentOS)
    systemctl start vnstat >/dev/null 2>&1 || true
    systemctl enable cron >/dev/null 2>&1 || systemctl enable crond >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || systemctl start crond >/dev/null 2>&1 || true
fi

# ---------------- 3. 自动配置定时任务 ----------------
CRON_5MIN="*/5 * * * * $SCRIPT_PATH >/dev/null 2>&1"
CRON_DAILY_12="0 12 * * * $SCRIPT_PATH send_tg >/dev/null 2>&1"

if ! crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then
    (crontab -l 2>/dev/null; echo "$CRON_5MIN"; echo "$CRON_DAILY_12") | crontab -
    echo "✅ 已成功配置定时任务：每 5 分钟双向流量监控，每天中午 12 点 TG 推送！"
fi

# ---------------- 4. Telegram 推送函数 ----------------
send_tg_msg() {
    TEXT=$1
    if [ -n "$TG_BOT_TOKEN" ] && [ "$TG_BOT_TOKEN" != "你的_BOT_TOKEN" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
             -d "chat_id=${TG_CHAT_ID}" \
             -d "text=${TEXT}" \
             -d "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi
}

# ---------------- 5. 流量统计与安全数据提取 ----------------
TIME_NOW=$(date "+%Y-%m-%d %H:%M:%S")

# 获取 JSON 数据
JSON_DATA=$(vnstat -i "$INTERFACE" --json m 1 2>/dev/null)

# 增强型提取，防止初次运行无月度数据时 jq 报错
RX_BYTES=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].rx' 2>/dev/null)
TX_BYTES=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0].tx' 2>/dev/null)

# 数据兜底判断
case "$RX_BYTES" in ''|'null'|*[!0-9]*) RX_BYTES=0 ;; esac
case "$TX_BYTES" in ''|'null'|*[!0-9]*) TX_BYTES=0 ;; esac

# 计算 GB (保留两位小数)
RX_GB=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES / 1024 / 1024 / 1024}")
TX_GB=$(awk "BEGIN {printf \"%.2f\", $TX_BYTES / 1024 / 1024 / 1024}")

# 输出控制台与追加日志
LOG_MSG="[$TIME_NOW] 入站: ${RX_GB} GB | 出站: ${TX_GB} GB | 单向限额: ${MAX_GB} GB"
echo "$LOG_MSG" | tee -a "$LOG_FILE"

# 日志清理 (保留最新 200 行)
tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"

# ---------------- 6. 逻辑分支判断 ----------------

# A. 手动测试或定时发送 TG 日报 (支持 send 或 send_tg 参数)
if [ "$1" = "send_tg" ] || [ "$1" = "send" ]; then
    TG_TEXT="📊 *VPS 每日双向流量日报*
📅 时间: \`${TIME_NOW}\`
📥 入站流量: *${RX_GB} GB* / *${MAX_GB} GB*
📤 出站流量: *${TX_GB} GB* / *${MAX_GB} GB*
⚙️ 状态: 正常监控中"
    send_tg_msg "$TG_TEXT"
    echo "推送指令已发送！"
    exit 0
fi

# B. 双向超限判定 (MB 为单位比较)
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
