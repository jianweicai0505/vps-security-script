#!/bin/bash

# ---------------- 参数配置 ----------------
INTERFACE="eth0"
MAX_GB=180
LOG_FILE="/root/lljk.log"
# ------------------------------------------

# 获取当前时间格式 (例如: 2026-07-27 15:42:31)
TIME_NOW=$(date "+%Y-%m-%d %H:%M:%S")

# 获取 JSON 数据
JSON_DATA=$(vnstat -i "$INTERFACE" --json m 1)

# 尝试提取当月 (rx + tx) 总字节数
TOTAL_BYTES=$(echo "$JSON_DATA" | jq -r '.interfaces[0].traffic.month[0] | select(. != null) | (.rx + .tx)')

# 如果 month 数组还没有数据（刚初始化），则默认字节数为 0
if [ -z "$TOTAL_BYTES" ] || [ "$TOTAL_BYTES" = "null" ]; then
    TOTAL_BYTES=0
fi

# 使用 awk 计算 GB 并保留两位小数
USED_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_BYTES / 1024 / 1024 / 1024}")

# 格式化输出字符串
LOG_MSG="[$TIME_NOW] 当前已用流量: ${USED_GB} GB / 限额: ${MAX_GB} GB"

# 打印到终端屏幕，同时追加到日志文件
echo "$LOG_MSG" | tee -a "$LOG_FILE"

# 日志自动清理：只保留最新的 200 行，防止日志文件膨胀
tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"

# 判断是否超出阈值 (换算成 MB 进行整数比较，更精准)
USED_MB=$((TOTAL_BYTES / 1024 / 1024))
MAX_MB=$((MAX_GB * 1024))

if [ "$USED_MB" -ge "$MAX_MB" ] && [ "$MAX_MB" -gt 0 ]; then
    WARN_MSG="[$TIME_NOW] 警告：当月流量已达到 ${MAX_GB} GB 阈值，准备关机！"
    echo "$WARN_MSG" | tee -a "$LOG_FILE"
    /sbin/poweroff
fi