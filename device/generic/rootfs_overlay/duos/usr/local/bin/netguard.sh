#!/bin/sh
# netguard.sh - Duo S 自适应 STA/AP 守护进程
# 状态机:
#   STA_OK    正常 STA（有线或 WiFi 已连接）
#   STA_RETRY 尝试连接 WiFi
#   AP        AP 模式（hostapd 运行）
# 触发:
#   有线(usb0/eth0 carrier+IP) > WiFi COMPLETED+IP > 扫描到已知网络 > AP 兜底

IFACE=wlan0
WPA_CONF=/etc/wpa_supplicant.conf
STATE_FILE=/var/run/netguard/state
RELOAD_MARKER=/var/run/netguard/reload
NETAP_CTL=/usr/local/bin/netap-ctl.sh
LOG=/var/log/netguard.log
CFG=/etc/netguard/netguard.conf
AP_CONF=/etc/netguard/hostapd.conf

# 默认参数（可被 /etc/netguard/netguard.conf 覆盖）
CYCLE=10          # 主循环周期(秒)
STA_TTL=45        # 等待 COMPLETED 超时(秒)
AP_MIN_UP=120     # AP 最小持续时长(秒)，防抖
BOOT_GRACE=10     # wlan0 出现后等待 S99auto.sh 处理 WiFi 的宽限(秒)
AP_SSID=""
AP_PASS=domour123
COUNTRY_CODE=CN

[ -f "$CFG" ] && . "$CFG"

# 如果 AP_SSID 为空或为旧默认值，生成带随机数的名称并写入配置持久化
if [ -z "$AP_SSID" ] || [ "$AP_SSID" = "DuoS-Setup" ]; then
    rand_num=$(tr -dc '0-9' </dev/urandom 2>/dev/null | head -c 4)
    [ -z "$rand_num" ] && rand_num=$((1000 + $$ % 9000))
    AP_SSID="Domour Copilot $rand_num"
    mkdir -p /etc/netguard
    echo "AP_SSID=\"$AP_SSID\"" >> "$CFG"
fi
if [ -z "$AP_PASS" ] || [ "$AP_PASS" = "duos-setup-1234" ]; then
    AP_PASS=domour123
    mkdir -p /etc/netguard
    echo "AP_PASS=\"$AP_PASS\"" >> "$CFG"
fi

# 自动将系统 Hostname 同步为 AP 命名 (例如 Domour Copilot 5531 -> domour-copilot-5531)
TARGET_HOSTNAME=$(echo "$AP_SSID" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
CURRENT_HOSTNAME=$(hostname 2>/dev/null)
if [ "$CURRENT_HOSTNAME" != "$TARGET_HOSTNAME" ]; then
    hostname "$TARGET_HOSTNAME" 2>/dev/null || true
    echo "$TARGET_HOSTNAME" > /etc/hostname 2>/dev/null || true
    if grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        sed -i "s/127.0.1.1.*/127.0.1.1\t$TARGET_HOSTNAME/" /etc/hosts 2>/dev/null || true
    else
        echo -e "127.0.1.1\t$TARGET_HOSTNAME" >> /etc/hosts 2>/dev/null || true
    fi
fi

mkdir -p /var/run/netguard /etc/netguard

log() { echo "$(date '+%F %T') [netguard] $*" >> "$LOG"; }
set_state() { echo "$1" > "$STATE_FILE"; }

# 有线(usb0/eth0)是否有链路且拿到 IP
wired_up() {
    for d in usb0 eth0; do
        [ -e "/sys/class/net/$d" ] || continue
        c=$(cat "/sys/class/net/$d/carrier" 2>/dev/null)
        [ "$c" = 1 ] || continue
        ip -4 addr show dev "$d" 2>/dev/null | grep -q 'inet ' && return 0
    done
    return 1
}

# WiFi 是否 COMPLETED 且拿到 IP
wifi_completed() {
    st=$(wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p')
    [ "$st" = "COMPLETED" ] && ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q 'inet '
}

wpa_running() { pidof wpa_supplicant >/dev/null 2>&1; }

# AP 是否真正在跑（pid 文件 + 进程存活双检查）
ap_running() {
    [ -f /var/run/hostapd.pid ] && [ -n "$(cat /var/run/hostapd.pid 2>/dev/null)" ] && [ -d "/proc/$(cat /var/run/hostapd.pid 2>/dev/null)" ]
}

# 清理 wlan0 上 AP 残留，回到 managed，确保 wpa_supplicant 运行
start_wpa() {
    killall hostapd 2>/dev/null
    sleep 1
    ip link set "$IFACE" down 2>/dev/null
    iw dev "$IFACE" set type managed 2>/dev/null
    ip link set "$IFACE" up 2>/dev/null
    ip addr del 192.168.5.1/24 dev "$IFACE" 2>/dev/null
    if wpa_running; then
        wpa_cli -i "$IFACE" reconfigure 2>/dev/null
    else
        wpa_supplicant -B -i "$IFACE" -c "$WPA_CONF"
        sleep 3
    fi
}

# 是否有已配置的有效 network 块（排除 SDK 默认占位 ssid="SSID"）
has_network_block() {
    grep -E '^[[:space:]]*ssid="[^"]+"' "$WPA_CONF" 2>/dev/null | grep -vq 'ssid="SSID"'
}

# 已知 SSID 是否在扫描范围内
known_ssid_in_range() {
    wpa_cli -i "$IFACE" scan >/dev/null 2>&1
    sleep 3
    res=$(wpa_cli -i "$IFACE" scan_results 2>/dev/null)
    found=1
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        echo "$res" | grep -Fq "$s" && { found=0; break; }
    done <<EOF
$(sed -n 's/^[[:space:]]*ssid="\([^"]*\)".*/\1/p' "$WPA_CONF")
EOF
    return $found
}

# 等待 WiFi 连上（最多 ttl 秒）；期间有线出现也算成功
wait_completed() {
    ttl=$1
    i=0
    while [ "$i" -lt "$ttl" ]; do
        wifi_completed && return 0
        wired_up && return 0
        sleep 3
        i=$((i + 3))
    done
    return 1
}

# 根据 /etc/netguard/netguard.conf 生成 hostapd.conf
gen_ap_conf() {
    cat > "$AP_CONF" <<EOF
interface=$IFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=6
country_code=$COUNTRY_CODE
ieee80211d=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_pairwise=CCMP
EOF
}

# 打开 AP 模式（生成配置后调用 netap-ctl）
ap_on() {
    gen_ap_conf
    $NETAP_CTL start
}

main() {
    set_state BOOT

    # 等待 wlan0 出现（驱动加载较慢）
    i=0
    while [ "$i" -lt 100 ] && [ ! -e "/sys/class/net/$IFACE" ]; do
        sleep 1; i=$((i + 1))
    done
    # 给 S99auto.sh 启动 wpa_supplicant 留出时间
    sleep "$BOOT_GRACE"

    AP_START=0

    while :; do
        now=$(date +%s)

        # ---- 0. reload 标记：Web 已保存新配置 → 无条件尝试 STA ----
        # 用户通过 Web 表单提交了 WiFi 信息，即使 USB 有网也应立即尝试连接验证
        if [ -f "$RELOAD_MARKER" ]; then
            rm -f "$RELOAD_MARKER"
            log "reload marker: trying STA"
            if ap_running; then
                $NETAP_CTL stop
            fi
            start_wpa
            if wait_completed "$STA_TTL"; then
                set_state STA_OK
            else
                log "STA retry failed, back to AP"
                ap_on
                set_state AP
                AP_START=$now
            fi
            sleep "$CYCLE"
            continue
        fi

        # ---- 1. 有线优先（首次未配置 WiFi 时仍保持 AP 供配置）----
        if wired_up; then
            # 有线有网但从未配置过 WiFi → 首次配置 AP 模式
            if ! has_network_block; then
                if ! ap_running; then
                    log "wired up but no wifi configured, starting AP (first-run setup)"
                    ap_on
                    AP_START=$now
                fi
                set_state AP
                sleep "$CYCLE"
                continue
            fi
            if ap_running; then
                log "wired detected, leaving AP"
                $NETAP_CTL stop
            fi
            # 有线在线的同时，也后台启动 wpa_supplicant 保持 WiFi 连接
            # 这样两个网络都可用，WiFi 用于日常局域网访问
            if ! wpa_running && has_network_block; then
                log "wired up, also starting wpa_supplicant for WiFi (best-effort)"
                wpa_supplicant -B -i "$IFACE" -c "$WPA_CONF" 2>/dev/null
                # 用专属 wlan.script 运行 udhcpc，自动以 metric 100 添加路由，与有线不冲突
                udhcpc -i "$IFACE" -s /usr/share/udhcpc/wlan.script -q -n 2>/dev/null || true
            fi
            set_state STA_OK
            sleep "$CYCLE"
            continue
        fi

        # ---- 2. 已连上 WiFi ----
        if wifi_completed; then
            if ap_running; then
                log "wifi connected, leaving AP"
                $NETAP_CTL stop
            fi
            set_state STA_OK
            sleep "$CYCLE"
            continue
        fi

        # ---- 3. AP 模式 ----
        if ap_running; then
            set_state AP
            # 首次配置模式（从未配置 WiFi）：保持 AP 等待配置
            if ! has_network_block; then
                sleep "$CYCLE"
                continue
            fi
            # 防抖：AP 至少保持 AP_MIN_UP
            if [ $((now - AP_START)) -lt "$AP_MIN_UP" ]; then
                sleep "$CYCLE"
                continue
            fi
            # 周期性检测：有线出现或已知网络可连 → 转 STA
            if wired_up; then
                log "wired detected, leaving AP"
                $NETAP_CTL stop
                set_state STA_OK
                AP_START=$now
                sleep "$CYCLE"
                continue
            fi
            if has_network_block && known_ssid_in_range; then
                log "known network in range, leaving AP"
                $NETAP_CTL stop
                start_wpa
                if wait_completed "$STA_TTL"; then
                    set_state STA_OK
                else
                    log "STA reconnect failed, staying in AP"
                    ap_on
                    set_state AP
                fi
            fi
            AP_START=$now
            sleep "$CYCLE"
            continue
        fi

        # ---- 4. 决策：尝试 STA 或开 AP ----
        set_state STA_RETRY

        if ! has_network_block; then
            log "no network block configured, starting AP"
            ap_on
            set_state AP
            AP_START=$now
            sleep "$CYCLE"
            continue
        fi

        if ! wpa_running; then
            start_wpa
            sleep 5
        fi

        if known_ssid_in_range; then
            if wait_completed "$STA_TTL"; then
                set_state STA_OK
                sleep "$CYCLE"
                continue
            fi
            log "STA connect timeout after ${STA_TTL}s"
        else
            log "no known ssid in range"
        fi

        # 连接失败 → AP 兜底
        ap_on
        set_state AP
        AP_START=$now
        sleep "$CYCLE"
    done
}

main
