#!/bin/bash

# ====================================================
# Smart Balancer V8.3
# 命令名称: balance
# 仓库地址: https://github.com/starshine369/smart_balancer
# ====================================================

CONFIG_FILE="/etc/smart_balancer.conf"
URLS_FILE="/etc/smart_balancer_urls.txt"
LOG_FILE="/var/log/smart_balancer.log"
SVC_FILE="/etc/systemd/system/smart_balancer.service"
BIN_FILE="/usr/local/bin/balance"
STATUS_FILE="/tmp/smart_balancer_status"

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[31m[!] 请使用 root 权限运行此脚本！\033[0m"
    exit 1
fi

set_conf() {
    if grep -q "^$1=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^$1=.*/$1=\"$2\"/" "$CONFIG_FILE"
    else
        echo "$1=\"$2\"" >> "$CONFIG_FILE"
    fi
}

# ==========================================
# Core 1: The Balancer Daemon
# ==========================================
if [ "$1" == "daemon" ]; then
    source "$CONFIG_FILE"
    RUN_MODE=${RUN_MODE:-4}
    SOURCE_STRATEGY=${SOURCE_STRATEGY:-1}
    ENABLE_SPEED_LIMIT=${ENABLE_SPEED_LIMIT:-0}
    MAX_SPEED_MB=${MAX_SPEED_MB:-20}
    TRIGGER_MB=${TRIGGER_MB:-10}
    TARGET_RATIO_10=$(awk "BEGIN {print int($TARGET_RATIO * 10)}")
    
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}
    YIELD_PERCENT=${YIELD_PERCENT:-85}
    CAPACITY_KB=$(( LINK_CAPACITY_MBPS * 1024 / 8 ))
    YIELD_THRESHOLD_KB=$(( CAPACITY_KB * YIELD_PERCENT / 100 ))

    DANGER_START_TIME=${DANGER_START_TIME:-1800}
    DANGER_END_TIME=${DANGER_END_TIME:-2330}
    IDLE_START_TIME=${IDLE_START_TIME:-0200}
    IDLE_END_TIME=${IDLE_END_TIME:-0800}
    IDLE_TX_LIMIT_KB=${IDLE_TX_LIMIT_KB:-100}

    DOWNLOAD_URLS=()
    if [ -f "$URLS_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -n "$line" ]] && [[ ! "$line" =~ ^#.* ]] && DOWNLOAD_URLS+=("$line")
        done < "$URLS_FILE"
    fi
    if [ ${#DOWNLOAD_URLS[@]} -eq 0 ]; then
        DOWNLOAD_URLS=("http://dldir1.qq.com/invc/tt/QQBrowser_Setup.exe" "http://dldir1.qq.com/weixin/mac/WeChatMac.dmg" "http://down.360safe.com/se/360se_setup.exe")
    fi

    CURL_PID=""
    IS_PAUSED=true
    DEBT_BYTES=0
    ACTIVATE_DEBT=$(( TRIGGER_MB * 1024 * 1024 ))
    ZOMBIE_COUNT=0
    # 日志自洁阈值：2MB
    MAX_LOG_SIZE=$(( 2 * 1024 * 1024 ))

    log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
        # 日志自洁机制：如果体积超过 2MB，则截断保留最后 1000 行
        if [[ -f "$LOG_FILE" ]]; then
            local current_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
            if [[ $current_size -gt $MAX_LOG_SIZE ]]; then
                tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [系统自洁] 日志触发 2MB 阈值，已自动物理切割截断。" >> "$LOG_FILE"
            fi
        fi
    }

    cleanup() {
        if [[ -n "$CURL_PID" ]] && kill -0 "$CURL_PID" 2>/dev/null; then kill -9 "$CURL_PID" 2>/dev/null || true; fi
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    get_traffic_bytes() {
        local res=$(awk -v iface="$IFACE" '$0 ~ iface":" { gsub(/:/, " ", $0); for(i=1; i<=NF; i++) { if($i == iface) { print $(i+1), $(i+9); break } } }' /proc/net/dev)
        if [[ -z "$res" ]]; then echo "0 0"; else echo "$res"; fi
    }

    is_time_in_range() {
        local start=$1; local end=$2
        local current=$(date +%H%M)
        current=$((10#$current)); start=$((10#$start)); end=$((10#$end))
        if [[ $start -le $end ]]; then
            if [[ $current -ge $start && $current -le $end ]]; then echo "yes"; else echo "no"; fi
        else
            if [[ $current -ge $start || $current -le $end ]]; then echo "yes"; else echo "no"; fi
        fi
    }

    start_curl() {
        source "$CONFIG_FILE"
        local strategy=${SOURCE_STRATEGY:-1}
        local url=""
        if [[ "$strategy" == "2" ]]; then
            local day_num=$(date +%j)
            local idx=$(( 10#$day_num % ${#DOWNLOAD_URLS[@]} ))
            url="${DOWNLOAD_URLS[$idx]}"
        else
            url="${DOWNLOAD_URLS[$((RANDOM % ${#DOWNLOAD_URLS[@]}))]}"
        fi

        if [[ -n "$CURL_PID" ]] && kill -0 "$CURL_PID" 2>/dev/null; then kill -9 "$CURL_PID" 2>/dev/null || true; fi
        local limit_cmd=""
        if [[ "$ENABLE_SPEED_LIMIT" == "1" ]] && [[ -n "$MAX_SPEED_MB" ]] && [[ "$MAX_SPEED_MB" -gt 0 ]]; then limit_cmd="--limit-rate ${MAX_SPEED_MB}M"; fi
        local user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0"
        nice -n 19 curl -f -s -o /dev/null $limit_cmd -A "$user_agent" --connect-timeout 5 -L "$url" &
        CURL_PID=$!
        IS_PAUSED=false
        ZOMBIE_COUNT=0
        log "[启动] 唤醒洗流通道 | 目标源: $url"
    }

    read -r PREV_RX_BYTES PREV_TX_BYTES <<< "$(get_traffic_bytes)"

    while true; do
        sleep 2
        read -r curr_rx curr_tx <<< "$(get_traffic_bytes)"
        delta_rx=$((curr_rx - PREV_RX_BYTES))
        delta_tx=$((curr_tx - PREV_TX_BYTES))

        if [[ $curr_rx -eq 0 && $curr_tx -eq 0 ]]; then
            echo -e "\033[31m[错误] 未能读取到网卡 $IFACE 的数据，请检查网卡名称！\033[0m" > "$STATUS_FILE"
            sleep 5; continue
        fi

        if [[ $delta_rx -lt 0 || $delta_tx -lt 0 ]]; then PREV_RX_BYTES=$curr_rx; PREV_TX_BYTES=$curr_tx; continue; fi

        tx_rate_kb=$(( delta_tx / 2 / 1024 ))
        rx_rate_kb=$(( delta_rx / 2 / 1024 ))

        IS_YIELDING=false
        if [[ $tx_rate_kb -gt $YIELD_THRESHOLD_KB || $rx_rate_kb -gt $YIELD_THRESHOLD_KB ]]; then IS_YIELDING=true; fi

        CAN_FLUSH="no"
        IN_DANGER="yes"

        if [[ "$RUN_MODE" == "1" ]]; then
            IN_DANGER=$(is_time_in_range "$DANGER_START_TIME" "$DANGER_END_TIME")
            CAN_FLUSH=$IN_DANGER
        elif [[ "$RUN_MODE" == "3" ]]; then
            CAN_FLUSH=$(is_time_in_range "$IDLE_START_TIME" "$IDLE_END_TIME")
        elif [[ "$RUN_MODE" == "4" ]]; then
            if [[ $tx_rate_kb -lt $IDLE_TX_LIMIT_KB ]]; then CAN_FLUSH="yes"; fi
        else
            CAN_FLUSH="yes"
        fi

        STATE_MSG="[待机] 账面平衡"

        if [[ "$IN_DANGER" == "no" ]]; then
            if [[ "$IS_PAUSED" == "false" ]]; then kill -STOP "$CURL_PID" 2>/dev/null; IS_PAUSED=true; DEBT_BYTES=0; fi
            STATE_MSG="\033[36m[休眠] 未在设定的定时对冲时段内\033[0m"
            PREV_RX_BYTES=$curr_rx; PREV_TX_BYTES=$curr_tx;
        else
            # 核心完美账本逻辑：不再干预上下限，回归真实记录
            expected_rx=$(( delta_tx * TARGET_RATIO_10 / 10 ))
            debt_diff=$(( expected_rx - delta_rx ))
            DEBT_BYTES=$(( DEBT_BYTES + debt_diff ))

            if [[ "$IS_YIELDING" == "true" ]]; then
                if [[ "$IS_PAUSED" == "false" ]]; then kill -STOP "$CURL_PID" 2>/dev/null; IS_PAUSED=true; fi
                STATE_MSG="\033[35m[避让] 物理带宽超限，主动让步给用户业务\033[0m"
            elif [[ "$CAN_FLUSH" == "no" ]]; then
                if [[ "$IS_PAUSED" == "false" ]]; then kill -STOP "$CURL_PID" 2>/dev/null; IS_PAUSED=true; fi
                STATE_MSG="\033[36m[错峰] 高峰期/上行非闲置，悬挂洗流任务仅记账\033[0m"
            else
                if [[ $DEBT_BYTES -gt $ACTIVATE_DEBT ]]; then
                    if [[ -z "$CURL_PID" ]] || ! kill -0 "$CURL_PID" 2>/dev/null; then
                        start_curl; STATE_MSG="\033[33m[初始化] 正在连接下载源...\033[0m"
                    elif [[ "$IS_PAUSED" == "true" ]]; then
                        kill -CONT "$CURL_PID" 2>/dev/null; IS_PAUSED=false
                    fi
                    
                    if [[ "$IS_PAUSED" == "false" ]]; then
                        STATE_MSG="\033[31m[洗流中] 满足开闸条件，平稳洗刷特征中...\033[0m"
                        # 防假死阈值下调至 50KB/s，防止限速带来的误杀
                        if [[ $rx_rate_kb -lt 50 ]]; then
                            ZOMBIE_COUNT=$(( ZOMBIE_COUNT + 1 ))
                            if [[ $ZOMBIE_COUNT -ge 3 ]]; then
                                start_curl; STATE_MSG="\033[35m[切换] 节点卡死，重新连接...\033[0m"
                            fi
                        else
                            ZOMBIE_COUNT=0
                        fi
                    fi
                else
                    if [[ "$IS_PAUSED" == "false" ]] && [[ $DEBT_BYTES -le 0 ]]; then
                        kill -STOP "$CURL_PID" 2>/dev/null; IS_PAUSED=true; ZOMBIE_COUNT=0
                    fi
                    if [[ "$IS_PAUSED" == "true" ]]; then STATE_MSG="\033[32m[待机] 账本归零或结余充足，进程冻结\033[0m"; fi
                fi
            fi
        fi

        abs_debt_mb=$(awk "BEGIN { if ($DEBT_BYTES < 0) printf \"%.2f\", -($DEBT_BYTES) / 1024 / 1024; else printf \"%.2f\", $DEBT_BYTES / 1024 / 1024 }")
        trigger_mb=$(awk "BEGIN { printf \"%.2f\", $ACTIVATE_DEBT / 1024 / 1024 }")
        
        if [[ $DEBT_BYTES -lt 0 ]]; then DEBT_STR="\033[32m结余 $abs_debt_mb\033[0m MB (充沛，为您无痕庇护后续上传)"
        else DEBT_STR="\033[33m欠款 $abs_debt_mb\033[0m MB / $trigger_mb MB (唤醒线)"; fi

        speed_status_cn=$( [[ "${ENABLE_SPEED_LIMIT:-0}" == "1" ]] && echo "已开启 (限速 ${MAX_SPEED_MB} MB/s)" || echo "未开启 (狂暴模式)" )
        mode_str_cn=""
        if [[ "$RUN_MODE" == "1" ]]; then mode_str_cn="模式 1 [定时对冲]"; elif [[ "$RUN_MODE" == "2" ]]; then mode_str_cn="模式 2 [全天候对冲]"
        elif [[ "$RUN_MODE" == "3" ]]; then mode_str_cn="模式 3 [闲时错峰-固定时段]"; elif [[ "$RUN_MODE" == "4" ]]; then mode_str_cn="模式 4 [闲时错峰-动态低负载]"
        fi

        echo -e "========== Smart Balancer 实时物理雷达 ==========" > "$STATUS_FILE"
        echo -e "监听网卡   : $IFACE | 运行模式: $mode_str_cn" >> "$STATUS_FILE"
        echo -e "物理带宽   : $LINK_CAPACITY_MBPS Mbps (防挤占警戒线: ${YIELD_PERCENT}%)" >> "$STATUS_FILE"
        echo -e "伪装下行比 : $TARGET_RATIO : 1" >> "$STATUS_FILE"
        echo -e "限速流控   : $speed_status_cn" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "实时上传   : \033[36m$tx_rate_kb KB/s\033[0m (代理真实上行)" >> "$STATUS_FILE"
        echo -e "实时下载   : \033[32m$rx_rate_kb KB/s\033[0m (全机总计下行)" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "流量账本   : $DEBT_STR" >> "$STATUS_FILE"
        echo -e "核心状态   : $STATE_MSG" >> "$STATUS_FILE"
        echo -e "================================================" >> "$STATUS_FILE"
        echo -e " [操作] 按 Ctrl+C 退出雷达面板" >> "$STATUS_FILE"

        PREV_RX_BYTES=$curr_rx; PREV_TX_BYTES=$curr_tx
    done
    exit 0
fi

# ==========================================
# Core 2: Install & Dashboard
# ==========================================
install_system() {
    if [[ ! -f "$0" || "$0" == "bash" || "$0" == "sh" || "$0" == "-bash" ]]; then
        echo -e "\033[31m[!] 错误：为保证完整性，请使用 wget 下载文件后执行！\033[0m"
        echo -e "指令：wget -O sb.sh https://ghproxy.net/https://raw.githubusercontent.com/starshine369/smart_balancer/main/smart_balancer.sh && bash sb.sh"
        exit 1
    fi

    clear
    echo "======================================================"
    echo "    [*] 正在部署 Smart Balancer 系统 V8.3"
    echo "======================================================"

    command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install curl awk -y || yum install curl awk -y; }

    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -Po '(?<=dev\s)\w+' | cut -f1 -d ' ' | head -n 1)
    read -p "[+] 确认监听网卡名 (默认: ${DEFAULT_IFACE:-ens5}): " IFACE
    IFACE=${IFACE:-${DEFAULT_IFACE:-ens5}}

    read -p "[+] 物理总带宽 (Mbps) [防挤占基准, 默认: 1000]: " LINK_CAPACITY_MBPS
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}
    YIELD_PERCENT=85

    read -p "[+] 伪装下行比 [默认: 1.5]: " TARGET_RATIO
    TARGET_RATIO=${TARGET_RATIO:-1.5}

    ENABLE_SPEED_LIMIT=1
    read -p "[+] 请输入伪装下载的限速阈值 (MB/s) [建议 15-30, 默认: 20]: " MAX_SPEED_MB
    MAX_SPEED_MB=${MAX_SPEED_MB:-20}

    echo "[*] 请选择运行模式 (共4种):"
    echo "  1) 定时对冲 (仅在设定时段内记账并洗流)"
    echo "  2) 全天候实时对冲 (全天记账，随时洗流)"
    echo "  3) 闲时错峰-固定时段 (全天记账，仅在设定的深夜等时段洗流)"
    echo "  4) 闲时错峰-动态负载 (全天记账，仅在机器上行速率极低时洗流，推荐!)"
    read -p ">>> 请选择 [默认: 4]: " RUN_MODE
    RUN_MODE=${RUN_MODE:-4}

    DANGER_START_TIME="1800"; DANGER_END_TIME="2330"
    IDLE_START_TIME="0200"; IDLE_END_TIME="0800"; IDLE_TX_LIMIT_KB=100

    if [[ "$RUN_MODE" == "1" ]]; then
        read -p "[+] 高危-开始时间 (HHMM, 默认: 1800): " DANGER_START_TIME
        read -p "[+] 高危-结束时间 (HHMM, 默认: 2330): " DANGER_END_TIME
    elif [[ "$RUN_MODE" == "3" ]]; then
        read -p "[+] 闲时-洗流开始时段 (HHMM, 默认 0200): " IDLE_START_TIME
        IDLE_START_TIME=${IDLE_START_TIME:-0200}
        read -p "[+] 闲时-洗流结束时段 (HHMM, 默认 0800): " IDLE_END_TIME
        IDLE_END_TIME=${IDLE_END_TIME:-0800}
    elif [[ "$RUN_MODE" == "4" ]]; then
        read -p "[+] 闲时-上行速率低于多少视为闲置无业务? (KB/s, 默认 100): " IDLE_TX_LIMIT_KB
        IDLE_TX_LIMIT_KB=${IDLE_TX_LIMIT_KB:-100}
    fi

    cat << CFGEOF > "$CONFIG_FILE"
IFACE="$IFACE"
LINK_CAPACITY_MBPS="$LINK_CAPACITY_MBPS"
YIELD_PERCENT="$YIELD_PERCENT"
TARGET_RATIO="$TARGET_RATIO"
RUN_MODE="$RUN_MODE"
DANGER_START_TIME="${DANGER_START_TIME:-1800}"
DANGER_END_TIME="${DANGER_END_TIME:-2330}"
SOURCE_STRATEGY="1"
ENABLE_SPEED_LIMIT="$ENABLE_SPEED_LIMIT"
MAX_SPEED_MB="$MAX_SPEED_MB"
TRIGGER_MB="10"
IDLE_START_TIME="${IDLE_START_TIME:-0200}"
IDLE_END_TIME="${IDLE_END_TIME:-0800}"
IDLE_TX_LIMIT_KB="${IDLE_TX_LIMIT_KB:-100}"
CFGEOF

    cat << URLEOF > "$URLS_FILE"
http://dldir1.qq.com/invc/tt/QQBrowser_Setup.exe
http://dldir1.qq.com/weixin/mac/WeChatMac.dmg
http://down.360safe.com/se/360se_setup.exe
URLEOF

    cp "$0" "$BIN_FILE"
    chmod +x "$BIN_FILE"

    cat << SVCEOF > "$SVC_FILE"
[Unit]
Description=Smart Balancer Traffic Camouflage
After=network.target

[Service]
Type=simple
ExecStart=$BIN_FILE daemon
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable smart_balancer > /dev/null 2>&1
    systemctl start smart_balancer
    echo -e "\033[32m[OK] Smart Balancer 安装完成！随时输入快捷指令: balance 唤出面板\033[0m"
    sleep 2
}

show_dashboard() {
    source "$CONFIG_FILE"
    ENABLE_SPEED_LIMIT=${ENABLE_SPEED_LIMIT:-0}
    MAX_SPEED_MB=${MAX_SPEED_MB:-20}
    TRIGGER_MB=${TRIGGER_MB:-10}
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}
    YIELD_PERCENT=${YIELD_PERCENT:-85}
    DANGER_START_TIME=${DANGER_START_TIME:-1800}
    DANGER_END_TIME=${DANGER_END_TIME:-2330}
    IDLE_START_TIME=${IDLE_START_TIME:-0200}
    IDLE_END_TIME=${IDLE_END_TIME:-0800}
    IDLE_TX_LIMIT_KB=${IDLE_TX_LIMIT_KB:-100}
    
    if systemctl is-active --quiet smart_balancer; then STATUS="\033[32m[引擎运转中 RUNNING]\033[0m"
    else STATUS="\033[31m[已停止 STOPPED]\033[0m"; fi

    if [[ "$RUN_MODE" == "1" ]]; then MODE_STR="[模式 1] 定时对冲 ($DANGER_START_TIME - $DANGER_END_TIME)"
    elif [[ "$RUN_MODE" == "2" ]]; then MODE_STR="[模式 2] 全天候 24/7 实时对冲"
    elif [[ "$RUN_MODE" == "3" ]]; then MODE_STR="[模式 3] 闲时错峰-固定时段 (闸门: $IDLE_START_TIME - $IDLE_END_TIME)"
    elif [[ "$RUN_MODE" == "4" ]]; then MODE_STR="[模式 4] 闲时错峰-动态负载 (闸门: TX < ${IDLE_TX_LIMIT_KB} KB/s)"
    else MODE_STR="未知模式"; fi

    clear
    echo "======================================================"
    echo "       Smart Balancer 流量对冲指挥台 V8.3"
    echo "======================================================"
    echo -e " [*] 核心状态   : $STATUS"
    echo " [*] 当前模式   : $MODE_STR"
    echo " [*] 伪装下行比 : $TARGET_RATIO : 1"
    echo " [*] 限速阀门   : $( [[ "$ENABLE_SPEED_LIMIT" == "1" ]] && echo "已开启 (限速阈值 ${MAX_SPEED_MB} MB/s)" || echo "未开启 (狂暴模式)" )"
    echo " [*] 防挤占设定 : $LINK_CAPACITY_MBPS Mbps (物理让步线: ${YIELD_PERCENT}%)"
    echo "======================================================"
    echo " [1] 切换 运行模式 (支持 4 种独立模式，带参数配置)"
    echo " [2] 切换 下载源策略 (随机切换 / 每日单源)"
    echo " [3] 修改 伪装下行比 (当前 $TARGET_RATIO)"
    echo " [4] 修改 伪装下载限速 (当前 ${MAX_SPEED_MB} MB/s)"
    echo " [5] 修改 唤醒防抖线 (当前 ${TRIGGER_MB} MB)"
    echo " [6] 设置 物理防挤占参数 (修改总带宽与让步百分比)"
    echo " [7] 修改 监听网卡 (当前 $IFACE)"
    echo -e " \033[32m[8] 打开 实时物理雷达 (观测无尽账本与错峰状态)\033[0m"
    echo " [9] 重启 对冲核心 (修改参数后必须执行生效)"
    echo " [88] 彻底 卸载系统"
    echo " [0] 退出 面板"
    echo "======================================================"
    read -p ">>> 请输入选项: " OPTION

    case $OPTION in
        1) 
            echo "========== 核心模式选择 =========="
            echo "  1) 定时对冲 (仅在设定时段内记账并洗流)"
            echo "  2) 全天候实时对冲 (全天记账，随时洗流)"
            echo "  3) 闲时错峰-固定时段 (全天记账，仅在设定的深夜等时段洗流)"
            echo "  4) 闲时错峰-动态负载 (全天记账，仅在机器上行速率极低时洗流，推荐!)"
            read -p ">>> 请选择 [1-4]: " NEW_MODE
            
            if [[ "$NEW_MODE" =~ ^[1-4]$ ]]; then
                set_conf "RUN_MODE" "$NEW_MODE"
                if [[ "$NEW_MODE" == "1" ]]; then
                    read -p "请输入高危-开始时段 (HHMM) [例如 1800]: " val_s; set_conf "DANGER_START_TIME" "${val_s:-1800}"
                    read -p "请输入高危-结束时段 (HHMM) [例如 2330]: " val_e; set_conf "DANGER_END_TIME" "${val_e:-2330}"
                elif [[ "$NEW_MODE" == "3" ]]; then
                    read -p "请输入闲时-洗流开始时段 (HHMM) [例如 0200]: " val_s; set_conf "IDLE_START_TIME" "${val_s:-0200}"
                    read -p "请输入闲时-洗流结束时段 (HHMM) [例如 0800]: " val_e; set_conf "IDLE_END_TIME" "${val_e:-0800}"
                elif [[ "$NEW_MODE" == "4" ]]; then
                    read -p "请输入判定为闲时的最高上行速率 (KB/s) [例如 100]: " val_kb; set_conf "IDLE_TX_LIMIT_KB" "${val_kb:-100}"
                fi
                echo "[OK] 模式与专属参数已更新，请按 [9] 重启生效。"
            else
                echo "[!] 选择无效。"
            fi
            sleep 1; show_dashboard ;;
        2)
            echo "1) 随机切换 (推荐，每次还款随机抽取源)"
            echo "2) 每日轮换 (每天 00:00 自动固定一个源)"
            read -p ">>> 请选择: " NEW_ST
            if [[ "$NEW_ST" =~ ^[1-2]$ ]]; then set_conf "SOURCE_STRATEGY" "$NEW_ST"; echo "[OK] 请按 [9] 重启生效。"; fi
            sleep 1; show_dashboard ;;
        3) 
            read -p "输入新的下行比 (例如 1.5): " NEW_RT
            if [ -n "$NEW_RT" ]; then set_conf "TARGET_RATIO" "$NEW_RT"; echo "[OK] 请按 [9] 重启生效。"; fi
            sleep 1; show_dashboard ;;
        4)
            read -p "是否开启限速? (1:开启 0:关闭，直接回车取消): " NEW_LIMIT_EN
            if [[ "$NEW_LIMIT_EN" == "1" || "$NEW_LIMIT_EN" == "0" ]]; then
                set_conf "ENABLE_SPEED_LIMIT" "$NEW_LIMIT_EN"
                if [[ "$NEW_LIMIT_EN" == "1" ]]; then
                    read -p "请输入新的限速阈值 (MB/s): " NEW_SPD
                    if [[ "$NEW_SPD" =~ ^[0-9]+$ ]]; then set_conf "MAX_SPEED_MB" "$NEW_SPD"; fi
                fi
                echo "[OK] 限速配置已更新，请按 [9] 重启生效。"
            fi
            sleep 1; show_dashboard ;;
        5) 
            read -p "请输入新的防抖触发线 (MB) (建议 10-50): " NEW_TRIGGER
            if [[ "$NEW_TRIGGER" =~ ^[0-9]+$ ]]; then set_conf "TRIGGER_MB" "$NEW_TRIGGER"; echo "[OK] 请按 [9] 重启生效。"; fi
            sleep 1; show_dashboard ;;
        6)
            read -p "请输入实际物理总带宽 (Mbps) [例如 1000]: " NEW_CAP
            if [[ "$NEW_CAP" =~ ^[0-9]+$ ]]; then
                set_conf "LINK_CAPACITY_MBPS" "$NEW_CAP"
                read -p "请输入触发避让的百分比 (%) [例如 85]: " NEW_PCT
                if [[ "$NEW_PCT" =~ ^[0-9]+$ ]]; then set_conf "YIELD_PERCENT" "$NEW_PCT"; fi
                echo "[OK] 物理防挤占参数已更新，请按 [9] 重启生效。"
            fi
            sleep 1; show_dashboard ;;
        7) 
            read -p "请输入新的外网网卡名称 (例如 eth0): " NEW_IFACE
            if [ -n "$NEW_IFACE" ]; then set_conf "IFACE" "$NEW_IFACE"; echo "[OK] 网卡已修改，请按 [9] 重启核心生效。"; fi
            sleep 1; show_dashboard ;;
        8) watch -n 1 -c cat /tmp/smart_balancer_status 2>/dev/null || while true; do clear; cat /tmp/smart_balancer_status 2>/dev/null; sleep 1; done ;;
        9) systemctl restart smart_balancer; echo "[OK] 核心已热重载！"; sleep 1; show_dashboard ;;
        88) systemctl stop smart_balancer; systemctl disable smart_balancer >/dev/null 2>&1; rm -f "$SVC_FILE" "$CONFIG_FILE" "$BIN_FILE" "$URLS_FILE" /tmp/smart_balancer_status; systemctl daemon-reload; echo "[OK] 系统已彻底卸载"; exit 0 ;;
        0) exit 0 ;;
        *) show_dashboard ;;
    esac
}

if [ ! -f "$CONFIG_FILE" ]; then install_system; show_dashboard; else show_dashboard; fi
