#!/bin/bash

# ====================================================
# Smart Balancer V7.0 (Pure Text Edition)
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
    TARGET_RATIO_10=$(awk "BEGIN {print int($TARGET_RATIO * 10)}")

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
    ACTIVATE_DEBT=$(( 1 * 1024 * 1024 ))
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
        local user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0"
        nice -n 19 curl -f -s -o /dev/null -A "$user_agent" --connect-timeout 5 -L "$url" &
        CURL_PID=$!
        IS_PAUSED=false
        ZOMBIE_COUNT=0
        log "[ACTION] Start Downloading | Strategy: $strategy | URL: $url"
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

            if [[ $DEBT_BYTES -gt $ACTIVATE_DEBT ]]; then
                if [[ -z "$CURL_PID" ]] || ! kill -0 "$CURL_PID" 2>/dev/null; then
                    start_curl
                    STATE_MSG="\033[33m[INIT] Connecting to source...\033[0m"
                elif [[ "$IS_PAUSED" == "true" ]]; then
                    kill -CONT "$CURL_PID" 2>/dev/null
                    IS_PAUSED=false
                    debt_mb=$(( DEBT_BYTES / 1024 / 1024 ))
                    log "[ALERT] Threshold crossed! Bursting download: ${debt_mb} MB"
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
                    log "[PAUSE] Balance restored, freezing process"
                fi
            fi
        fi

        debt_mb_display=$(awk "BEGIN { printf \"%.2f\", $DEBT_BYTES / 1024 / 1024 }")
        trigger_mb=$(awk "BEGIN { printf \"%.2f\", $ACTIVATE_DEBT / 1024 / 1024 }")

        echo -e "========== Smart Balancer Physical Radar ==========" > "$STATUS_FILE"
        echo -e "Interface  : $IFACE" >> "$STATUS_FILE"
        echo -e "Target Ratio : $TARGET_RATIO : 1" >> "$STATUS_FILE"
        echo -e "Strategy   : $( [[ ${SOURCE_STRATEGY:-1} == "2" ]] && echo "Daily Rotation" || echo "Random Switch" )" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "TX Rate    : \033[36m$tx_rate_kb KB/s\033[0m (Proxy Upload)" >> "$STATUS_FILE"
        echo -e "RX Rate    : \033[32m$rx_rate_kb KB/s\033[0m (Total Download)" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "Traffic Debt : \033[33m$debt_mb_display MB\033[0m / $trigger_mb MB (Limit)" >> "$STATUS_FILE"
        echo -e "Core Status  : $STATE_MSG" >> "$STATUS_FILE"
        echo -e "================================================" >> "$STATUS_FILE"
        echo -e " [INFO] Press Ctrl+C to exit radar" >> "$STATUS_FILE"

        PREV_RX_BYTES=$curr_rx; PREV_TX_BYTES=$curr_tx
    done
    exit 0
fi

# ==========================================
# Core 2: Install & Dashboard
# ==========================================
install_system() {
    if [[ ! -f "$0" || "$0" == "bash" || "$0" == "sh" || "$0" == "-bash" ]]; then
        echo -e "\033[31m[ERROR] Please use wget to download and run as file!\033[0m"
        echo -e "Command: wget -O sb.sh https://raw.githubusercontent.com/starshine369/smart_balancer/main/smart_balancer.sh && bash sb.sh"
        exit 1
    fi

    clear
    echo "======================================================"
    echo "    [*] Deploying Smart Balancer System V7.0"
    echo "======================================================"

    command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install curl awk -y || yum install curl awk -y; }

    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -Po '(?<=dev\s)\w+' | cut -f1 -d ' ' | head -n 1)
    read -p "[+] Net Interface (Default: ${DEFAULT_IFACE:-ens5}): " IFACE
    IFACE=${IFACE:-${DEFAULT_IFACE:-ens5}}

    read -p "[+] Total Bandwidth (Mbps) [Default: 1000]: " LINK_CAPACITY_MBPS
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}

    read -p "[+] Target Ratio [Default: 1.5]: " TARGET_RATIO
    TARGET_RATIO=${TARGET_RATIO:-1.5}

    read -p "[+] Run Mode (1:Timer 2:24/7) [Default: 2]: " RUN_MODE
    RUN_MODE=${RUN_MODE:-2}

    DANGER_START_TIME="1800"; DANGER_END_TIME="2330"
    if [[ "$RUN_MODE" == "1" ]]; then
        read -p "[+] Start Time (HHMM, Default: 1800): " DANGER_START_TIME
        read -p "[+] End Time (HHMM, Default: 2330): " DANGER_END_TIME
    fi

    cat << CFGEOF > "$CONFIG_FILE"
IFACE="$IFACE"
LINK_CAPACITY_MBPS="$LINK_CAPACITY_MBPS"
TARGET_RATIO="$TARGET_RATIO"
RUN_MODE="$RUN_MODE"
DANGER_START_TIME="${DANGER_START_TIME:-1800}"
DANGER_END_TIME="${DANGER_END_TIME:-2330}"
SOURCE_STRATEGY="1"
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
    echo -e "\033[32m[OK] Smart Balancer Installed! Alias: balance\033[0m"
    sleep 2
}

show_dashboard() {
    source "$CONFIG_FILE"
    if systemctl is-active --quiet smart_balancer; then STATUS="\033[32m[RUNNING]\033[0m"
    else STATUS="\033[31m[STOPPED]\033[0m"; fi

    clear
    echo "======================================================"
    echo "       Smart Balancer Dashboard V7.0 (Pure Text)"
    echo "======================================================"
    echo -e " [*] Core Status    : $STATUS"
    echo " [*] Net Interface  : $IFACE"
    echo " [!] Run Mode       : $( [[ "$RUN_MODE" == "2" ]] && echo "24/7 Mode" || echo "Timer ($DANGER_START_TIME - $DANGER_END_TIME)" )"
    echo " [*] Source Strategy: $( [[ "$SOURCE_STRATEGY" == "2" ]] && echo "Daily Rotation" || echo "Random Switch" )"
    echo " [*] Target Ratio   : $TARGET_RATIO : 1"
    echo "======================================================"
    echo " [1] Change Run Mode (Timer / 24/7)"
    echo " [2] Change Source Strategy (Random / Daily)"
    echo " [3] Change Target Ratio (Current: $TARGET_RATIO)"
    echo -e " \033[32m[4] Open Physical Radar (Monitor Balancing)\033[0m"
    echo " [5] View History Logs"
    echo " [6] Restart Core (Apply changes)"
    echo " [9] Uninstall System"
    echo " [0] Exit"
    echo "======================================================"
    read -p ">>> Select option: " OPTION

    case $OPTION in
        1) read -p "Select (1:Timer 2:24/7): " NEW_MODE; sed -i "s/^RUN_MODE=.*/RUN_MODE=\"$NEW_MODE\"/" "$CONFIG_FILE"; echo "[OK] Restart to apply"; sleep 1; show_dashboard ;;
        2) 
            echo "1) Random Switch (Default)"
            echo "2) Daily Rotation (Change source every 00:00)"
            read -p ">>> Choice: " NEW_ST
            sed -i "s/^SOURCE_STRATEGY=.*/SOURCE_STRATEGY=\"$NEW_ST\"/" "$CONFIG_FILE"
            echo "[OK] Restart to apply"; sleep 1; show_dashboard ;;
        3) read -p "New ratio: " NEW_RT; sed -i "s/^TARGET_RATIO=.*/TARGET_RATIO=\"$NEW_RT\"/" "$CONFIG_FILE"; echo "[OK] Restart to apply"; sleep 1; show_dashboard ;;
        4) watch -n 1 -c cat /tmp/smart_balancer_status 2>/dev/null || while true; do clear; cat /tmp/smart_balancer_status 2>/dev/null; sleep 1; done ;;
        5) tail -f "$LOG_FILE" ;;
        6) systemctl restart smart_balancer; echo "Core Reloaded!"; sleep 1; show_dashboard ;;
        9) systemctl stop smart_balancer; systemctl disable smart_balancer >/dev/null 2>&1; rm -f "$SVC_FILE" "$CONFIG_FILE" "$BIN_FILE" "$URLS_FILE" /tmp/smart_balancer_status; systemctl daemon-reload; echo "[OK] Uninstalled"; exit 0 ;;
        0) exit 0 ;;
        *) show_dashboard ;;
    esac
}

if [ ! -f "$CONFIG_FILE" ]; then install_system; show_dashboard; else show_dashboard; fi