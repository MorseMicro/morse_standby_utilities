#!/bin/sh
#
# Copyright 2024-2026 Morse Micro
# SPDX-License-Identifier: MIT
#
# Test script for emulating host wakeup when the firmware signals standby exit.
#
# Must be invoked from morse_standby_daemon.sh - functions and parameters are inherited.
#
# This script performs the following operations.
# 1. Resolves the configured host wake GPIO to a GPIO character device line and requests it as an
#    input.
# 2. Emulates host shutdown by stopping wpa_supplicant.
# 3. Monitors the wake GPIO for a debounced state change and periodically probes the firmware to
#    detect manual standby exit.
# 4. When wakeup is detected, cleans up the GPIO state, restarts the Morse Micro host services, and
#    restarts morse_standby_daemon.sh.
#
# Requirements
# - A GPIO line must be allocated for waking the host.

set -u

# Run in this script's directory
cd -- "$(dirname -- "$0")" || exit 1

# Period for polling the GPIO wake pin (two representations of the same value)
wake_pin_check_interval_s=0.05
wake_pin_check_interval_ms=50

# Milliseconds between checks for a responsive chip
chip_query_interval_ms=5000

procname="morse_standby_wake_monitor.sh"
hw_version="$(morse_cli -i "$c_interface" hw_version | awk '/Version/ {print $NF}')"
gpio_exported=false
gpiochip="gpiochip0"
gpio_path=""
read_gpio_cmd=""

log_pin_status()
{
    channel=$1
    pin_status=$2

    case "$pin_status" in
        0) pin_label="low"
            ;;
        *) pin_label="high"
            ;;
    esac

    logmsg -v "Pin $channel state: $pin_label"
}

monitor_cleanup()
{
    logmsg -v "Exiting wake monitor"

    if "$gpio_exported" && [ -w /sys/class/gpio/unexport ]; then
        logmsg -v "echo \"$c_wake_monitor_gpio\" > /sys/class/gpio/unexport"
        echo "$c_wake_monitor_gpio" > /sys/class/gpio/unexport
        gpio_exported=false
    fi
}

wake_init()
{
    # This is only used if gpioget is not installed
    gpio_path="/sys/class/gpio/gpio$c_wake_monitor_gpio"
}

request_gpio()
{
    if command -v gpioget >/dev/null 2>&1; then
        if gpioget --version 2>/dev/null | grep -q ' v1\.'; then
            logmsg -v "Ignoring gpioget v1 for GPIO polling; using sysfs fallback"
        else
            if docmd gpioget --numeric -c "$gpiochip" "$c_wake_monitor_gpio"; then
                read_gpio_cmd="gpioget --numeric -c $gpiochip $c_wake_monitor_gpio"
                return
            else
                errmsg "Failed using gpioget v2 to get GPIO $gpiochip pin $c_wake_monitor_gpio"
            fi
        fi
    fi

    if [ ! -d /sys/class/gpio ]; then
        errmsg "GPIO sysfs interface not present"
        exit 1
    fi

    if [ ! -d "$gpio_path" ]; then
        if ! echo "$c_wake_monitor_gpio" > /sys/class/gpio/export; then
            errmsg "Failed to export GPIO pin $c_wake_monitor_gpio"
            exit 1
        fi
        gpio_exported=true
    fi

    if ! echo "in" > "$gpio_path/direction"; then
        errmsg "Failed to configure GPIO direction for $gpio_path"
        exit 1
    fi

    read_gpio_cmd="cat $gpio_path/value"
}

read_gpio_value()
{
    if ! value=$(eval "$read_gpio_cmd" 2>/dev/null); then
        return 1
    fi

    case "$value" in
        0|1)
            printf '%s\n' "$value"
            return 0
            ;;
    esac

    return 1
}

emulate_shutdown()
{
    if $is_openwrt || $is_fullmac; then
        # Standby exit doesn't work on OpenWrt if wpa_supplicant is shut down
        logmsg "Skipping shutdown emulation"
    else
        logmsg "Emulating shutdown by stopping wpa_supplicant"

        # Busybox does not have -e but lists all processes
        if ps -e >/dev/null 2>&1; then
            ps_all_cmd="ps -e"
        else
            ps_all_cmd="ps"
        fi

        pids=$($ps_all_cmd | \
            grep -w "wpa_supplicant_s1g" | \
            grep -vw grep | \
            awk '{print $1}')
        echo "$pids" | while IFS= read -r pid; do
            logmsg -v "kill $pid"
            kill "$pid" >/dev/null 2>&1
        done
    fi
}

wake_cmd()
{
    logmsg -v "$@"
    printf 'CMD: %s\n' "$*" >>$logfile
    "$@" >>$logfile 2>&1
}

emulate_wakeup()
{
    logfile="/tmp/morse_standby_wake_cmd.log"

    trap - EXIT

    monitor_cleanup

    # This is not necessary, but will cause the chip wakeup reason to be printed
    docmd morse_cli -i "$c_interface" standby exit

    logmsg "Emulating wakeup > $logfile"

    rm -f "$logfile"

    if $is_openwrt; then
        wake_cmd wifi down
        wake_cmd rmmod morse
        wake_cmd wifi up
    elif $is_fullmac; then
        wake_cmd /config/morse/morse_init.sh
    else
        wake_cmd /etc/init.d/S99morse restart
    fi

    logmsg "Restarting morse_standby_daemon.sh"
    ./morse_standby_daemon.sh &

    exit
}

check_firmware()
{
    if morse_cli -i "$c_interface" get wake_action_gpio >/dev/null 2>&1; then
        logmsg "$hw_version is responsive - emulate wakeup"
        emulate_wakeup
    else
        logmsg -v "$hw_version is in standby mode"
    fi
}

monitor_wake_pin()
{
    logmsg "Monitoring host GPIO pin $c_wake_monitor_gpio and probing firmware"
    logmsg -v "Using $read_gpio_cmd to monitor the wake pin"

    if ! current_status=$(read_gpio_value); then
        errmsg "Failed to read GPIO pin $c_wake_monitor_gpio from $gpiochip"
        exit 1
    fi
    log_pin_status "$c_wake_monitor_gpio" "$current_status"

    polls_per_chip_query=$((chip_query_interval_ms / wake_pin_check_interval_ms))
    polls_per_debounce=$((c_wake_monitor_debounce_ms / wake_pin_check_interval_ms))
    polls_since_chip_query=0
    # Allow the first observed edge to fire without waiting for a debounce window.
    polls_since_edge=$polls_per_debounce

    while :; do
        sleep "$wake_pin_check_interval_s"

        # Periodically detect for manual standby exit (e.g. via "morse_cli standby exit").
        polls_since_chip_query=$((polls_since_chip_query + 1))
        if [ "$polls_since_chip_query" -ge "$polls_per_chip_query" ]; then
            polls_since_chip_query=0
            check_firmware
        fi

        if ! observed_status=$(read_gpio_value); then
            errmsg "Failed to read GPIO pin $c_wake_monitor_gpio from $gpiochip"
            continue
        fi

        polls_since_edge=$((polls_since_edge + 1))

        if [ "$observed_status" = "$current_status" ]; then
            continue
        fi
        current_status=$observed_status

        if [ "$polls_since_edge" -lt "$polls_per_debounce" ]; then
            polls_since_edge=0
            continue
        fi
        polls_since_edge=0

        log_pin_status "$c_wake_monitor_gpio" "$current_status"
        logmsg "$hw_version has toggled the wake pin - emulate wakeup"
        emulate_wakeup
    done
}

wake_init

trap 'exit 0' INT TERM HUP QUIT
trap monitor_cleanup EXIT

set -u

request_gpio

emulate_shutdown

monitor_wake_pin
