#!/bin/bash

# ====================================================
# Smart Balancer V7.1 (纯净中文扩展版)
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
    
    # 黄金三源 (剔除慢速源，保留百兆级极速源)
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
        log "[启动] 唤醒下载通道 | 策略: ${strategy} | 目标源: $url"
    }

    read -r PREV_RX_BYTES PREV_TX_BYTES <<< "$(get_traffic_bytes)"

    while true; do
        sleep 2
        read -r curr_rx curr_tx <<< "$(get_traffic_bytes)"
        delta_rx=$((curr_rx - PREV_RX_BYTES))
        delta_tx=$((curr_tx - PREV_TX_BYTES))

        if [[ $curr_rx -eq 0 && $curr_tx -eq 0 ]]; then
            echo -e "\033[31m[错误] 未能读取到网卡 $IFACE 的数据，请检查网卡名称！\033[0m" > "$STATUS_FILE"
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

        STATE_MSG="[待机] 账面平衡"

        if [[ "$IN_DANGER" == "no" ]]; then
            if [[ "$IS_PAUSED" == "false" ]]; then
                kill -STOP "$CURL_PID" 2>/dev/null
                IS_PAUSED=true
                DEBT_BYTES=0
            fi
            STATE_MSG="\033[36m[休眠] 未在设定的监控时段\033[0m"
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
                    STATE_MSG="\033[33m[初始化] 正在连接下载源...\033[0m"
                elif [[ "$IS_PAUSED" == "true" ]]; then
                    kill -CONT "$CURL_PID" 2>/dev/null
                    IS_PAUSED=false
                    debt_mb=$(( DEBT_BYTES / 1024 / 1024 ))
                    log "[警报] 欠账越过红线! 爆拉下行补齐: ${debt_mb} MB"
                fi
                
                if [[ "$IS_PAUSED" == "false" ]]; then
                    STATE_MSG="\033[31m[对冲中] 正在疯狂下载补齐特征...\033[0m"
                    if [[ $rx_rate_kb -lt 200 ]]; then
                        ZOMBIE_COUNT=$(( ZOMBIE_COUNT + 1 ))
                        if [[ $ZOMBIE_COUNT -ge 3 ]]; then
                            log "[警告] 下载通道假死或被限速，强行物理猎杀并换源！"
                            start_curl
                            STATE_MSG="\033[35m[切换] 节点卡死，正在重新连接备用节点...\033[0m"
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
                    log "[暂停] 债务已清偿，冻结下载进程"
                fi
            fi
        fi

        debt_mb_display=$(awk "BEGIN { printf \"%.2f\", $DEBT_BYTES / 1024 / 1024 }")
        trigger_mb=$(awk "BEGIN { printf \"%.2f\", $ACTIVATE_DEBT / 1024 / 1024 }")

        echo -e "========== Smart Balancer 物理雷达 ==========" > "$STATUS_FILE"
        echo -e "监听网卡 : $IFACE" >> "$STATUS_FILE"
        echo -e "设定的比例 : $TARGET_RATIO : 1" >> "$STATUS_FILE"
        echo -e "下载策略 : $( [[ ${SOURCE_STRATEGY:-1} == "2" ]] && echo "每日自动轮换" || echo "每次随机切换" )" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "实时上传 : \033[36m$tx_rate_kb KB/s\033[0m (代理上传业务量)" >> "$STATUS_FILE"
        echo -e "实时下载 : \033[32m$rx_rate_kb KB/s\033[0m (全机总计下行量)" >> "$STATUS_FILE"
        echo -e "------------------------------------------------" >> "$STATUS_FILE"
        echo -e "流量欠款 : \033[33m$debt_mb_display MB\033[0m / $trigger_mb MB (唤醒触发线)" >> "$STATUS_FILE"
        echo -e "核心状态 : $STATE_MSG" >> "$STATUS_FILE"
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
        echo -e "指令：wget -O sb.sh https://raw.githubusercontent.com/starshine369/smart_balancer/main/smart_balancer.sh && bash sb.sh"
        exit 1
    fi

    clear
    echo "======================================================"
    echo "    [*] 正在部署 Smart Balancer 系统 V7.1 (中文版)"
    echo "======================================================"

    command -v curl >/dev/null 2>&1 || { apt-get update -y && apt-get install curl awk -y || yum install curl awk -y; }

    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -Po '(?<=dev\s)\w+' | cut -f1 -d ' ' | head -n 1)
    read -p "[+] 确认监听网卡名 (默认: ${DEFAULT_IFACE:-ens5}): " IFACE
    IFACE=${IFACE:-${DEFAULT_IFACE:-ens5}}

    read -p "[+] 物理总带宽 (Mbps) [默认: 1000]: " LINK_CAPACITY_MBPS
    LINK_CAPACITY_MBPS=${LINK_CAPACITY_MBPS:-1000}

    read -p "[+] 伪装下行比 [默认: 1.5]: " TARGET_RATIO
    TARGET_RATIO=${TARGET_RATIO:-1.5}

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
    echo -e "\033[32m[OK] Smart Balancer 安装完成！随时输入快捷指令: balance 唤出面板\033[0m"
    sleep 2
}

show_dashboard() {
    source "$CONFIG_FILE"
    if systemctl is-active --quiet smart_balancer; then STATUS="\033[32m[引擎运转中 RUNNING]\033[0m"
    else STATUS="\033[31m[已停止 STOPPED]\033[0m"; fi

    clear
    echo "======================================================"
    echo "       Smart Balancer 流量对冲指挥台 V7.1"
    echo "======================================================"
    echo -e " [*] 核心状态   : $STATUS"
    echo " [*] 监听网卡   : $IFACE"
    echo " [!] 运行模式   : $( [[ "$RUN_MODE" == "2" ]] && echo "全天候 24/7 对冲" || echo "定时伪装 ($DANGER_START_TIME - $DANGER_END_TIME)" )"
    echo " [*] 下载策略   : $( [[ "$SOURCE_STRATEGY" == "2" ]] && echo "每日自动轮换单源" || echo "随机切换极速源" )"
    echo " [*] 伪装下行比 : $TARGET_RATIO : 1"
    echo "======================================================"
    echo " [1] 切换 运行模式 (全天候 / 定时)"
    echo " [2] 切换 下载源策略 (随机切换 / 每日单源)"
    echo " [3] 修改 伪装下行比 (当前 $TARGET_RATIO)"
    echo " [4] 修改 监听网卡 (当前 $IFACE)"
    echo -e " \033[32m[5] 打开 实时物理雷达 (实时观测特征洗白过程)\033[0m"
    echo " [6] 查看 后台历史日志"
    echo " [7] 重启 对冲核心 (修改参数后必须执行生效)"
    echo " [9] 彻底 卸载系统"
    echo " [0] 退出 面板"
    echo "======================================================"
    read -p ">>> 请输入选项: " OPTION

    case $OPTION in
        1) read -p "选(1:定时 2:全天): " NEW_MODE; sed -i "s/^RUN_MODE=.*/RUN_MODE=\"$NEW_MODE\"/" "$CONFIG_FILE"; echo "[OK] 请按 [7] 重启生效"; sleep 1; show_dashboard ;;
        2) 
            echo "1) 随机切换 (推荐，每次还款随机抽取源)"
            echo "2) 每日轮换 (每天 00:00 自动固定一个源)"
            read -p ">>> 请选择: " NEW_ST
            sed -i "s/^SOURCE_STRATEGY=.*/SOURCE_STRATEGY=\"$NEW_ST\"/" "$CONFIG_FILE"
            echo "[OK] 请按 [7] 重启生效"; sleep 1; show_dashboard ;;
        3) read -p "输入新的下行比 (例如 1.5): " NEW_RT; sed -i "s/^TARGET_RATIO=.*/TARGET_RATIO=\"$NEW_RT\"/" "$CONFIG_FILE"; echo "[OK] 请按 [7] 重启生效"; sleep 1; show_dashboard ;;
        4) 
            read -p "请输入新的外网网卡名称 (例如 eth0, ens5): " NEW_IFACE
            if [ -n "$NEW_IFACE" ]; then
                sed -i "s/^IFACE=.*/IFACE=\"$NEW_IFACE\"/" "$CONFIG_FILE"
                echo "[OK] 网卡已修改，请按 [7] 重启核心生效。"
            else
                echo "[!] 不能为空！"
            fi
            sleep 1; show_dashboard ;;
        5) watch -n 1 -c cat /tmp/smart_balancer_status 2>/dev/null || while true; do clear; cat /tmp/smart_balancer_status 2>/dev/null; sleep 1; done ;;
        6) tail -f "$LOG_FILE" ;;
        7) systemctl restart smart_balancer; echo "[OK] 核心已热重载！"; sleep 1; show_dashboard ;;
        9) systemctl stop smart_balancer; systemctl disable smart_balancer >/dev/null 2>&1; rm -f "$SVC_FILE" "$CONFIG_FILE" "$BIN_FILE" "$URLS_FILE" /tmp/smart_balancer_status; systemctl daemon-reload; echo "[OK] 系统已彻底卸载"; exit 0 ;;
        0) exit 0 ;;
        *) show_dashboard ;;
    esac
}

if [ ! -f "$CONFIG_FILE" ]; then install_system; show_dashboard; else show_dashboard; fi