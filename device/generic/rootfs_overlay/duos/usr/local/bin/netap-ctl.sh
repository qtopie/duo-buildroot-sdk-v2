#!/bin/sh
# netap-ctl.sh - AP 模式启停控制（Duo S）
# 用法: netap-ctl.sh {start|stop|status}
#
# 依赖二进制（部署时从 SDK 拷贝）:
#   /usr/local/bin/hostapd      (duo-buildroot-sdk-v2/ramdisk/rootfs/public/wifi/musl_riscv64/usr/sbin/hostapd)
# 配置:
#   /etc/netguard/hostapd.conf  (AP 配置)

IFACE=wlan0
AP_IP=192.168.5.1
NETMASK=255.255.255.0
HOSTAPD=/usr/local/bin/hostapd
HOSTAPD_CONF=/etc/netguard/hostapd.conf
HOSTAPD_PID=/var/run/hostapd.pid
DNSMASQ=/usr/sbin/dnsmasq
DNS_CONF=/etc/dnsmasq.conf
DNS_PID=/var/run/dnsmasq.pid
LOG=/var/log/netguard.log

log() { echo "$(date '+%F %T') [netap-ctl] $*" >> "$LOG"; }

# 删除 dnsmasq 配置中由 netguard 追加的 wlan0 网段
cleanup_dnsmasq() {
    sed -i '/^# ===netguard-ap===/,/^# ===end netguard-ap===/d' "$DNS_CONF" 2>/dev/null
}

restart_dnsmasq() {
    killall dnsmasq 2>/dev/null
    sleep 1
    "$DNSMASQ" --pid-file="$DNS_PID" 2>/dev/null
}

start_ap() {
    is_ap && { log "AP already running"; return 0; }

    # 1. 停 STA 与 udhcpc，避免与 hostapd 抢 wlan0
    killall wpa_supplicant 2>/dev/null
    killall udhcpc 2>/dev/null
    sleep 1

    # 2. wlan0 切到 AP 模式（顺序参考实测：先配 IP up → down → set type ap → up）
    ifconfig "$IFACE" "$AP_IP" netmask "$NETMASK" up 2>/dev/null
    ip link set "$IFACE" down
    iw dev "$IFACE" set type ap 2>>"$LOG"
    ip link set "$IFACE" up

    # 3. 启动 hostapd
    "$HOSTAPD" -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF" >>"$LOG" 2>&1 || {
        log "hostapd start failed"; return 1; }

    # 4. dnsmasq 追加 wlan0 DHCP 网段并重启（服务 AP 客户端）
    cleanup_dnsmasq
    {
        echo "# ===netguard-ap==="
        echo "interface=wlan0"
        echo "dhcp-range=192.168.5.100,192.168.5.200,12h"
        echo "dhcp-option=3"
        echo "dhcp-option=6"
        echo "# ===end netguard-ap==="
    } >> "$DNS_CONF"
    restart_dnsmasq

    log "AP started ($IFACE: $AP_IP)"
    return 0
}

stop_ap() {
    if ! is_ap; then
        log "AP not running, nothing to stop"
        return 0
    fi

    # 1. 停 hostapd
    killall hostapd 2>/dev/null
    sleep 1

    # 2. 还原 dnsmasq 配置
    cleanup_dnsmasq
    restart_dnsmasq

    # 3. wlan0 切回 managed，清残留地址/路由
    ip link set "$IFACE" down 2>/dev/null
    iw dev "$IFACE" set type managed 2>>"$LOG"
    ip link set "$IFACE" up 2>/dev/null
    ip addr del "$AP_IP"/24 dev "$IFACE" 2>/dev/null
    ip route del 192.168.5.0/24 dev "$IFACE" 2>/dev/null

    log "AP stopped"
    return 0
}

is_ap() {
    [ -f "$HOSTAPD_PID" ] && [ -n "$(cat "$HOSTAPD_PID" 2>/dev/null)" ] && [ -d "/proc/$(cat "$HOSTAPD_PID" 2>/dev/null)" ]
}

case "$1" in
    start)  start_ap ;;
    stop)   stop_ap ;;
    status)
        if is_ap; then echo "AP: running ($IFACE: $AP_IP)"; else echo "AP: stopped"; fi ;;
    *)
        echo "usage: $0 {start|stop|status}" >&2; exit 1 ;;
esac
