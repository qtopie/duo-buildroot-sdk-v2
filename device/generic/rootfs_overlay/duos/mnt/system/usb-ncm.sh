#!/bin/sh
# Milk-V Duo S USB Device/NCM Mode Initialization
# Dynamically adapts to Linux 5.10 / Linux 7.3+ GPIO numbering
# Hardware pins:
#   USB_SELECT: XGPIOA[30] (0 = Type-C, 1 = Type-A)
#   USB_EN:     XGPIOB[5]  (0 = 5V VBUS Off, 1 = 5V VBUS On)

LOG_FILE="/tmp/ncm.log"

find_gpio_base() {
    local target="$1"
    local fallback="$2"
    for chip in /sys/class/gpio/gpiochip*; do
        [ -d "$chip" ] || continue
        local label=""
        if [ -f "$chip/label" ]; then
            label=$(cat "$chip/label" 2>/dev/null)
        fi
        case "$label" in
            *"$target"*)
                cat "$chip/base" 2>/dev/null && return 0
                ;;
        esac
    done
    echo "$fallback"
}

porta_base=$(find_gpio_base "3020000" "544")
portb_base=$(find_gpio_base "3021000" "576")

if [ -d "/sys/class/gpio/gpiochip480" ]; then
    porta_base=480
    portb_base=448
fi

usb_select=$((porta_base + 30))
usb_en=$((portb_base + 5))

set_gpio() {
    local gpio_num="$1"
    local gpio_val="$2"
    local gpio_path="/sys/class/gpio/gpio${gpio_num}"

    if [ ! -d "${gpio_path}" ]; then
        echo "${gpio_num}" > /sys/class/gpio/export 2>/dev/null || true
    fi

    if [ -d "${gpio_path}" ]; then
        echo out > "${gpio_path}/direction" 2>/dev/null || true
        usleep 50000 2>/dev/null || sleep 0.1
        echo "${gpio_val}" > "${gpio_path}/value" 2>/dev/null || true
    fi
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Activating USB Device/NCM Mode (Type-C)..." >> "${LOG_FILE}"
echo "GPIO Base: porta=${porta_base} (sel=${usb_select}), portb=${portb_base} (en=${usb_en})" >> "${LOG_FILE}"

# Step 1: Turn off Type-A 5V VBUS power (USB_EN = 0)
set_gpio "${usb_en}" 0
usleep 100000 2>/dev/null || sleep 0.1

# Step 2: Switch PHY data path to Type-C (USB_SELECT = 0)
set_gpio "${usb_select}" 0
usleep 100000 2>/dev/null || sleep 0.1

# Step 3: Trigger legacy drivers if present
if [ -x "/etc/uhubon.sh" ]; then
    /etc/uhubon.sh device >> "${LOG_FILE}" 2>&1
fi
if [ -x "/etc/run_usb.sh" ]; then
    /etc/run_usb.sh probe ncm >> "${LOG_FILE}" 2>&1
    /etc/run_usb.sh start ncm >> "${LOG_FILE}" 2>&1
fi

# Step 4: Configure IP for usb0 if interface exists
if ifconfig usb0 192.168.42.1 netmask 255.255.255.0 up 2>/dev/null; then
    echo "Configured usb0 with 192.168.42.1" >> "${LOG_FILE}"
fi

# Step 5: Start dnsmasq if not running
if ! pidof dnsmasq >/dev/null 2>&1; then
    if [ -x "/etc/init.d/S80dnsmasq" ]; then
        /etc/init.d/S80dnsmasq start >> "${LOG_FILE}" 2>&1
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] USB Device/NCM Mode activated successfully." >> "${LOG_FILE}"
