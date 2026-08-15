#!/bin/sh

function set_gpio()
{
	local gpio_num=$1
	local gpio_val=$2
	local gpio_path="/sys/class/gpio/gpio${gpio_num}"

	if test -d ${gpio_path}; then
		echo "GPIO ${gpio_num} already exported" >> /tmp/gpio.log 2>&1
	else
		echo ${gpio_num} > /sys/class/gpio/export
	fi

	echo out > ${gpio_path}/direction
	sleep 0.1
	echo ${gpio_val} > ${gpio_path}/value
}

# Hardware V1.1
gpio_b17=465
set_gpio ${gpio_b17} 0

# Host Wake BT
host_wake_bt=362
set_gpio ${host_wake_bt} 1

# WIFI/BT Module
# Auto-generate and persist unique MAC address on first boot
INI_FILE="/mnt/system/firmware/aic8800/rwnx_settings.ini"
if [ ! -f "$INI_FILE" ] || ! grep -q "MAC_ADDR=" "$INI_FILE"; then
	mkdir -p /mnt/system/firmware/aic8800
	R1=$(hexdump -n 1 -e '1/1 "%02x"' /dev/urandom 2>/dev/null || echo "ab")
	R2=$(hexdump -n 1 -e '1/1 "%02x"' /dev/urandom 2>/dev/null || echo "9c")
	echo "MAC_ADDR=88:00:33:77:${R1}:${R2}" > "$INI_FILE"
	sync
fi

insmod /mnt/system/ko/aic8800_bsp.ko
sleep 0.5
insmod /mnt/system/ko/aic8800_fdrv.ko
insmod /mnt/system/ko/aic8800_btlpm.ko

# Insmod PWM Module
insmod /mnt/system/ko/cv181x_pwm.ko

