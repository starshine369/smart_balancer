#!/bin/bash

# ====================================================
# Smart Balancer V7.4 (物理带宽防挤占版)
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

# ==========================================
# Core 1: The Balancer Daemon
# ==========================================
if [ "$1" == "daemon" ]; then
    source "$CONFIG_FILE"
    RUN_MODE=${RUN_MODE:-2}
    SOURCE_STRATEGY=${SOURCE_STRATEGY:-1}
    ENABLE_SPEED_LIMIT=${ENABLE_SPEED_LIMIT:-0}
    MAX_SPEED_MB=${MAX_SPEED_MB:-20}
    TRIGGER_MB=${TRIGGER_MB:-10}
    TARGET_RATIO_10=$(awk "BEGIN {print int($TARGET_RATIO * 10)}")
    
    # 防挤占参数读取
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}
    YIELD_PERCENT=${YIELD_PERCENT:-85}
    CAPACITY_KB=$(( LINK_CAPACITY_MBPS * 1024 / 8 ))
    YIELD_THRESHOLD_KB=$(( CAPACITY_KB * YIELD_PERCENT / 100 ))

    DOWNLOAD_URLS=()
    if [ -f "$URLS_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -n "$line" ]] && [[ ! "$line" =~ ^#.* ]] && DOWNLOAD_URLS+=("$line")
        done < "$URLS_FILE"
    fi
    
    if [ ${#DOWNLOAD_URLS[@]} -eq 0 ]; then
        DOWNLOAD_URLS=(
            "http://dldir1.qq.com/invc/tt/QQBrowser_Setup.exe"
            "http://dldir1.qq.com/weixin/mac/WeChatMac.dmg"
            "http://down.360safe.com/se/360se_setup.exe"
        )
    fi

    CURL_PID=""
    IS_PAUSED=true
    DEBT_BYTES=0
    MAX_DEBT=$(( 500 * 1024 * 1024 ))
    ACTIVATE_DEBT=$(( TRIGGER_MB * 1024 * 1024 ))
    ZOMBIE_COUNT=0

    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

    cleanup() {
        if [[ -n "$CURL_PID" ]] && kill -0 "$CURL_PID" 2>/dev/null; then kill -9 "$CURL_PID" 2>/dev/null || true; fi
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    get_traffic_bytes() {
        local res=$(awk -v iface="$IFACE" '$0 ~ iface":" { gsub(/:/, " ", $0); for(i=1; i<=NF; i++) { if($i == iface) { print $(i+1), $(i+9); break } } }' /proc/net/dev)
        if [[ -z "$res" ]]; then echo "0 0"; else echo "$res"; fi
    }

    is_danger_zone() {
        local current_time=$(date +%H%M)
        current_time=$((10#$current_time))
        local start=$((10#$DANGER_START_TIME))
        local end=$((10#$DANGER_END_TIME))
        if [[ "$start" -le "$end" ]]; then
            if [[ "$current_time" -ge "$start" ]] && [[ "$current_time" -le "$end" ]]; then echo "yes"; else echo "no"; fi
        else
            if [[ "$current_time" -ge "$start" ]] || [[ "$current_time" -le "$end" ]]; then echo "yes"; else echo "no"; fi
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
        if [[ "$ENABLE_SPEED_LIMIT" == "1" ]] && [[ -n "$MAX_SPEED_MB" ]] && [[ "$MAX_SPEED_MB" -gt 0 ]]; then
            limit_cmd="--limit-rate ${MAX_SPEED_MB}M"
        fi

        local user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0"
        nice -n 19 curl -f -s -o /dev/null $limit_cmd -A "$user_agent" --connect-timeout 5 -L "$url" &
        CURL_PID=$!
        IS_PAUSED=false
        ZOMBIE_COUNT=0
        log "[ACTION] Start Downloading | URL: $url"
    }

    read -r PREV_RX_BYTES PREV_TX_BYTES <<< "$(get_traffic_bytes)"

    while true; do
        sleep 2
        read -r curr_rx curr_tx <<< "$(get_traffic_bytes)"
        delta_rx=$((curr_rx - PREV_RX_BYTES))
        delta_tx=$((curr_tx - PREV_TX_BYTES))

        if [[ $curr_rx -eq 0 && $curr_tx -eq 0 ]]; then
            echo -e "\033[31m[ERROR] Network interface $IFACE NOT FOUND!\033[0m" > "$STATUS_FILE"
            sleep 5
            continue
        fi

        if [[ $delta_rx -lt 0 || $delta_tx -lt 0 ]]; then
            PREV_RX_BYTES=$curr_rx; PREV_TX_BYTES=$curr_tx; continue
        fi

        tx_rate_kb=$(( delta_tx / 2 / 1024 ))
        rx_rate_kb=$(( delta_rx / 2 / 1024 ))

        # 核心防挤占逻辑计算
        IS_YIELDING=false
        if [[ $tx_rate_kb -gt $YIELD_THRESHOLD_KB || $rx_rate_kb -gt $YIELD_THRESHOLD_KB ]]; then
            IS_YIELDING=true
        fi

        IN_DANGER="no"
        if [[ "$RUN_MODE" == "2" ]]; then IN_DANGER="yes"; else IN_DANGER=$(is_danger_zone); fi

        STATE_MSG="[IDLE] Balance OK"

        if [[ "$IN_DANGER" == "no" ]]; then
            if [[ "$IS_PAUSED" == "false" ]]; then
                kill -STOP "$CURL_PID" 2>/dev/null
                IS_PAUSED=true
                DEBT_BYTES=0
            fi
            STATE_MSG="\033[36m[SLEEP] Outside dangerous hours\033[0m"
            PREV_RX_BYTES=$curr_rx; PREV_TX_BYTES=$curr_tx;
        else
            expected_rx=$(( delta_tx * TARGET_RATIO_10 / 10 ))
            debt_diff=$(( expected_rx - delta_rx ))
            DEBT_BYTES=$(( DEBT_BYTES + debt_diff ))

            [[ $DEBT_BYTES -lt 0 ]] && DEBT_BYTES=0
            [[ $DEBT_BYTES -gt $MAX_DEBT ]] && DEBT_BYTES=$MAX_DEBT

            if [[ "$IS_YIELDING" == "true" ]]; then
                # 防挤占让步状态
                if [[ "$IS_PAUSED" == "false" ]]; then
                    kill -STOP "$CURL_PID" 2>/dev/null
                    IS_PAUSED=true
                    log "[YIELD] Physical bandwidth > ${YIELD_PERCENT}%. Pausing proxy traffic to yield."
                fi
                STATE_MSG="\033[35m[YIELD] Bandwidth maxed out. Yielding to user traffic.\033[0m"
            else
                # 正常刷流逻辑
                if [[ $DEBT_BYTES -gt $ACTIVATE_DEBT ]]; then
                    if [[ -z "$CURL_PID" ]] || ! kill -0 "$CURL_PID" 2>/dev/null; then
                        start_curl
                        STATE_MSG="\033[33m[INIT] Connecting to source...\033[0m"
                    elif [[ "$IS_PAUSED" == "true" ]]; then
                        kill -CONT "$CURL_PID" 2>/dev/null
                        IS_PAUSED=false
                        debt_mb=$(( DEBT_BYTES / 1024 / 1024 ))
                        log "[ALERT] Threshold crossed (${TRIGGER_MB}MB)! Resuming download."
                    fi
                    
                    if [[ "$IS_PAUSED" == "false" ]]; then
                        STATE_MSG="\033[31m[RUNNING] Balancing traffic...\033[0m"
                        if [[ $rx_rate_kb -lt 200 ]]; then
                            ZOMBIE_COUNT=$(( ZOMBIE_COUNT + 1 ))
                            if [[ $ZOMBIE_COUNT -ge 3 ]]; then
                                log "[WARN] Channel stalled. Killing and switching source."
                                start_curl
                                STATE_MSG="\033[35m[SWITCH] Dead link killed, retrying...\033[0m"
                            fi
                        else
                            ZOMBIE_COUNT=0
                        fi
                    fi
                else
                    if [[ "$IS_PAUSED" == "false" ]]; then
                        kill -STOP "$CURL_PID" 2>/dev/null
                        IS_PAUSED=true
                        ZOMBIE_COUNT=0
                        log "[PAUSE] Balance restored, freezing process."
                    fi
                fi
            fi
        fi

        debt_mb_display=$(awk "BEGIN { printf \"%.2f\", $DEBT_BYTES / 1024 / 1024 }")
        trigger_mb=$(awk "BEGIN { printf \"%.2f\", $ACTIVATE_DEBT / 1024 / 1024 }")
        speed_status=$( [[ "${ENABLE_SPEED_LIMIT:-0}" == "1" ]] && echo "Enabled (Max ${MAX_SPEED_MB} MB/s)" || echo "Disabled (Unlimited)" )

        echo -e "========== Smart Balancer Physical Radar ==========" > "$STATUS_FILE"
        echo -e "Interface  : $IFACE" >> "$STATUS_FILE"
        echo -e "Bandwidth  : $LINK_CAPACITY_MBPS Mbps (Yield @ $YIELD_PERCENT%)" >> "$STATUS_FILE"
        echo -e "Ratio Limit: $TARGET_RATIO : 1" >> "$STATUS_FILE"
        echo -e "Speed Valve: $speed_status" >> "$STATUS_FILE"
        echo -e "Strategy   : $( [[ ${SOURCE_STRATEGY:-1} == "2" ]] && echo "Daily Rotation" || echo "Random Switch" )" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "TX Rate    : \033[36m$tx_rate_kb KB/s\033[0m (Proxy Upload)" >> "$STATUS_FILE"
        echo -e "RX Rate    : \033[32m$rx_rate_kb KB/s\033[0m (Total Download)" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "Traffic Debt : \033[33m$debt_mb_display MB\033[0m / $trigger_mb MB (Wake Line)" >> "$STATUS_FILE"
        echo -e "Core Status  : $STATE_MSG" >> "$STATUS_FILE"
        echo -e "================================================" >> "$STATUS_FILE"
        echo -e " [INFO] Press Ctrl+C to exit radar panel" >> "$STATUS_FILE"

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
    echo "    [*] 正在部署 Smart Balancer 系统 V7.4 (防挤占版)"
    echo "======================================================"

    command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install curl awk -y || yum install curl awk -y; }

    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -Po '(?<=dev\s)\w+' | cut -f1 -d ' ' | head -n 1)
    read -p "[+] 确认监听网卡名 (默认: ${DEFAULT_IFACE:-ens5}): " IFACE
    IFACE=${IFACE:-${DEFAULT_IFACE:-ens5}}

    read -p "[+] 物理总带宽 (Mbps) [此项用于防挤占计算, 默认: 1000]: " LINK_CAPACITY_MBPS
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}

    read -p "[+] 物理防挤占让步线 (%) [建议 80-90, 默认: 85]: " YIELD_PERCENT
    YIELD_PERCENT=${YIELD_PERCENT:-85}

    read -p "[+] 伪装下行比 [默认: 1.5]: " TARGET_RATIO
    TARGET_RATIO=${TARGET_RATIO:-1.5}

    read -p "[+] 唤醒触发线 (MB) (积攒多少欠款才唤醒下载，防抖动) [默认: 10]: " TRIGGER_MB
    TRIGGER_MB=${TRIGGER_MB:-10}

    read -p "[+] 是否开启平滑限速? 开启后能消除尖峰超调。 (1:开启 0:关闭) [默认: 1]: " ENABLE_SPEED_LIMIT
    ENABLE_SPEED_LIMIT=${ENABLE_SPEED_LIMIT:-1}
    
    if [[ "$ENABLE_SPEED_LIMIT" == "1" ]]; then
        read -p "[+] 请输入最高下载速度上限 (MB/s) [默认: 15]: " MAX_SPEED_MB
        MAX_SPEED_MB=${MAX_SPEED_MB:-15}
    else
        MAX_SPEED_MB=20
    fi

    read -p "[+] 选模式 (1:定时高危 2:全天候) [默认: 2]: " RUN_MODE
    RUN_MODE=${RUN_MODE:-2}

    DANGER_START_TIME="1800"; DANGER_END_TIME="2330"
    if [[ "$RUN_MODE" == "1" ]]; then
        read -p "[+] 开始时间 (HHMM, 默认: 1800): " DANGER_START_TIME
        read -p "[+] 结束时间 (HHMM, 默认: 2330): " DANGER_END_TIME
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
TRIGGER_MB="$TRIGGER_MB"
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
    # 兼容老配置变量
    ENABLE_SPEED_LIMIT=${ENABLE_SPEED_LIMIT:-0}
    MAX_SPEED_MB=${MAX_SPEED_MB:-20}
    TRIGGER_MB=${TRIGGER_MB:-10}
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}
    YIELD_PERCENT=${YIELD_PERCENT:-85}
    
    if systemctl is-active --quiet smart_balancer; then STATUS="\033[32m[引擎运转中 RUNNING]\033[0m"
    else STATUS="\033[31m[已停止 STOPPED]\033[0m"; fi

    clear
    echo "======================================================"
    echo "       Smart Balancer 流量对冲指挥台 V7.4"
    echo "======================================================"
    echo -e " [*] 核心状态   : $STATUS"
    echo " [*] 监听网卡   : $IFACE"
    echo " [*] 物理总带宽 : $LINK_CAPACITY_MBPS Mbps (物理防挤占线: ${YIELD_PERCENT}%)"
    echo " [!] 运行模式   : $( [[ "$RUN_MODE" == "2" ]] && echo "全天候 24/7 对冲" || echo "定时伪装 ($DANGER_START_TIME - $DANGER_END_TIME)" )"
    echo " [*] 下载策略   : $( [[ "$SOURCE_STRATEGY" == "2" ]] && echo "每日自动轮换单源" || echo "每次随机切换极速源" )"
    echo " [*] 伪装下行比 : $TARGET_RATIO : 1"
    echo " [*] 限速阀门   : $( [[ "$ENABLE_SPEED_LIMIT" == "1" ]] && echo "已开启 (峰值限制 ${MAX_SPEED_MB} MB/s)" || echo "未开启 (狂暴模式)" )"
    echo " [*] 唤醒触发线 : ${TRIGGER_MB} MB"
    echo "======================================================"
    echo " [1] 切换 运行模式 (全天候 / 定时)"
    echo " [2] 切换 下载源策略 (随机切换 / 每日单源)"
    echo " [3] 修改 伪装下行比 (当前 $TARGET_RATIO)"
    echo " [4] 修改 唤醒触发线 (当前 ${TRIGGER_MB} MB)"
    echo " [5] 设置 下载限速流控 (限流防超调)"
    echo " [6] 设置 物理防挤占参数 (修改物理带宽与让步百分比)"
    echo " [7] 修改 监听网卡 (当前 $IFACE)"
    echo -e " \033[32m[8] 打开 实时物理雷达 (观测主动让步状态)\033[0m"
    echo " [9] 重启 对冲核心 (修改参数后必须执行生效)"
    echo " [88] 彻底 卸载系统"
    echo " [0] 退出 面板"
    echo "======================================================"
    read -p ">>> 请输入选项: " OPTION

    case $OPTION in
        1) read -p "选(1:定时 2:全天): " NEW_MODE; sed -i "s/^RUN_MODE=.*/RUN_MODE=\"$NEW_MODE\"/" "$CONFIG_FILE"; echo "[OK] 请按 [9] 重启生效"; sleep 1; show_dashboard ;;
        2) 
            echo "1) 随机切换 (推荐，每次还款随机抽取源)"
            echo "2) 每日轮换 (每天 00:00 自动固定一个源)"
            read -p ">>> 请选择: " NEW_ST
            sed -i "s/^SOURCE_STRATEGY=.*/SOURCE_STRATEGY=\"$NEW_ST\"/" "$CONFIG_FILE"
            echo "[OK] 请按 [9] 重启生效"; sleep 1; show_dashboard ;;
        3) read -p "输入新的下行比 (例如 1.5): " NEW_RT; sed -i "s/^TARGET_RATIO=.*/TARGET_RATIO=\"$NEW_RT\"/" "$CONFIG_FILE"; echo "[OK] 请按 [9] 重启生效"; sleep 1; show_dashboard ;;
        4) 
            read -p "请输入新的触发线 (MB) (建议 10-50): " NEW_TRIGGER
            if [[ "$NEW_TRIGGER" =~ ^[0-9]+$ ]]; then
                if grep -q "^TRIGGER_MB=" "$CONFIG_FILE"; then
                    sed -i "s/^TRIGGER_MB=.*/TRIGGER_MB=\"$NEW_TRIGGER\"/" "$CONFIG_FILE"
                else
                    echo "TRIGGER_MB=\"$NEW_TRIGGER\"" >> "$CONFIG_FILE"
                fi
                echo "[OK] 触发线已修改为 ${NEW_TRIGGER} MB，请按 [9] 重启生效。"
            else
                echo "[!] 输入无效，必须为整数。"
            fi
            sleep 1; show_dashboard ;;
        5)
            read -p "是否开启限速? (1:开启 0:关闭，直接回车取消): " NEW_LIMIT_EN
            if [[ "$NEW_LIMIT_EN" == "1" || "$NEW_LIMIT_EN" == "0" ]]; then
                if grep -q "^ENABLE_SPEED_LIMIT=" "$CONFIG_FILE"; then
                    sed -i "s/^ENABLE_SPEED_LIMIT=.*/ENABLE_SPEED_LIMIT=\"$NEW_LIMIT_EN\"/" "$CONFIG_FILE"
                else
                    echo "ENABLE_SPEED_LIMIT=\"$NEW_LIMIT_EN\"" >> "$CONFIG_FILE"
                fi
                
                if [[ "$NEW_LIMIT_EN" == "1" ]]; then
                    read -p "请输入新的速度上限 (MB/s): " NEW_SPD
                    if [[ "$NEW_SPD" =~ ^[0-9]+$ ]]; then
                        if grep -q "^MAX_SPEED_MB=" "$CONFIG_FILE"; then
                            sed -i "s/^MAX_SPEED_MB=.*/MAX_SPEED_MB=\"$NEW_SPD\"/" "$CONFIG_FILE"
                        else
                            echo "MAX_SPEED_MB=\"$NEW_SPD\"" >> "$CONFIG_FILE"
                        fi
                    fi
                fi
                echo "[OK] 限速配置已更新，请按 [9] 重启生效。"
            fi
            sleep 1; show_dashboard ;;
        6)
            read -p "请输入实际物理总带宽 (Mbps) [例如 1000]: " NEW_CAP
            if [[ "$NEW_CAP" =~ ^[0-9]+$ ]]; then
                sed -i "s/^LINK_CAPACITY_MBPS=.*/LINK_CAPACITY_MBPS=\"$NEW_CAP\"/" "$CONFIG_FILE"
                read -p "请输入触发避让的百分比 (%) [例如 85]: " NEW_PCT
                if [[ "$NEW_PCT" =~ ^[0-9]+$ ]]; then
                    if grep -q "^YIELD_PERCENT=" "$CONFIG_FILE"; then
                        sed -i "s/^YIELD_PERCENT=.*/YIELD_PERCENT=\"$NEW_PCT\"/" "$CONFIG_FILE"
                    else
                        echo "YIELD_PERCENT=\"$NEW_PCT\"" >> "$CONFIG_FILE"
                    fi
                    echo "[OK] 物理防挤占参数已更新，请按 [9] 重启生效。"
                fi
            fi
            sleep 1; show_dashboard ;;
        7) 
            read -p "请输入新的外网网卡名称 (例如 eth0, ens5): " NEW_IFACE
            if [ -n "$NEW_IFACE" ]; then
                sed -i "s/^IFACE=.*/IFACE=\"$NEW_IFACE\"/" "$CONFIG_FILE"
                echo "[OK] 网卡已修改，请按 [9] 重启核心生效。"
            fi
            sleep 1; show_dashboard ;;
        8) watch -n 1 -c cat /tmp/smart_balancer_status 2>/dev/null || while true; do clear; cat /tmp/smart_balancer_status 2>/dev/null; sleep 1; done ;;
        9) systemctl restart smart_balancer; echo "[OK] 核心已热重载！"; sleep 1; show_dashboard ;;
        88) systemctl stop smart_balancer; systemctl disable smart_balancer >/dev/null 2>&1; rm -f "$SVC_FILE" "$CONFIG_FILE" "$BIN_FILE" "$URLS_FILE" /tmp/smart_balancer_status; systemctl daemon-reload; echo "[OK] 系统已彻底卸载"; exit 0 ;;
        0) exit 0 ;;
        *) show_dashboard ;;
    esac
}

if [ ! -f "$CONFIG_FILE" ]; then install_system; show_dashboard; else show_dashboard; fi