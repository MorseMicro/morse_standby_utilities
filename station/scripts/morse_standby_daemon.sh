#!/bin/sh
#
# Copyright 2022-2026 Morse Micro
# SPDX-License-Identifier: MIT
#
# Morse Micro standby mode daemon
#
# This daemon performs the following operations.
# 1. Applies the standby configuration to a Morse Micro 802.11ah interface.
# 2. Monitors the interface state:
#    - when associated, waits for a configured period with no transmitted or received data
#    - when not associated and scan_ssid is configured, waits for the configured number of poll
#      periods
# 3. When either of these standby entry conditions are met:
#    - instructs the chip to enter standby mode
#    - optionally saves ARP entries for restoration after wakeup
# 4. After entering standby mode, either:
#    - invokes a user-specified Linux command to power off or hibernate the host device
#    - or runs a test wake monitor script that watches the wake GPIO and emulates host restart
#
# Refer to Morse Micro Application Note 22: "Standby Mode and Connection Reattach" document for
# further information.
#
# Refer to Morse Micro Application Note 21: "Offload Features" document for a full description of
# offload features, several of which may be useful when utilizing standby mode.
#
# Make changes to this script as required to suit your environment and requirement. Remove all
# unused functionality, to improve script parsing time.

set -u

# Run in this script's directory
cd -- "$(dirname -- "$0")" || exit 1

is_fullmac=false
is_openwrt=false
if [ -r /etc/openwrt_release ]; then
    is_openwrt=true
    default_config_file="/etc/morse_standby_daemon.conf"
elif [ "$(cat /sys/module/morse/parameters/enable_wiphy 2>/dev/null)" = "Y" ]; then
    is_fullmac=true
    default_config_file="/config/morse/morse_standby_daemon.conf"
else
    default_config_file="/morse/configs/morse_standby_daemon.conf"
fi

procname=$(basename "$0")
if $is_fullmac; then
    # Use persistent config due to reboot
    saved_arp_entries="/config/morse/$procname.arp_entries"
else
    saved_arp_entries="/var/run/$procname.arp_entries"
    saved_dhcp_entries="/var/run/$procname.dhcp_entries"
fi

usage()
{
cat <<EOF
$procname [<config file>]
Configure standby mode, then monitor Wi-Fi activity and enter standby mode when no
data traffic has been sent to or received from the interface for a specified period.

<config file>           Configuration file (default: $default_config_file)
-h                      Display this help
EOF
}

logmsg()
{
    if [ "$1" = "-v" ]; then
        if ! $c_verbose; then
            return
        fi
        shift
    fi

    if $c_foreground; then
        printf '%s %s %s\n' "$(date +%H:%M:%S)" "$procname" "$*"
    else
        logger -t "$procname" -- "$*"
    fi
}

errmsg()
{
    if $c_foreground; then
        printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2
    else
        logger -t "$procname" -- "$*"
    fi
}

docmd()
{
    output=$("$@" 2>&1)
    ret=$?

    if $c_verbose; then
        logmsg "CMD: $*"
        if [ -n "$output" ]; then
            if $c_foreground; then
                printf '%s\n' "$output"
            else
                logger -t "$procname" -- "$output"
            fi
        fi
    fi

    return $ret
}

known_config_keys()
{
    cat <<'EOF'
interface
poll_period
standby_config_file
scan_ssid
not_assoc_poll_periods
save_arp_entries
save_dhcp_entries
wake_monitor_test_script
wake_monitor_gpio
wake_monitor_debounce_ms
verbose
config_report
foreground
EOF
}

init_config()
{
    c_foreground=false
    c_verbose=false
    c_config_report=false
    c_interface="wlan0"
    c_poll_period=15
    c_standby_config_file="standby.conf"
    c_scan_ssid=""
    c_not_assoc_poll_periods=4
    c_save_arp_entries=true
    c_save_dhcp_entries=true

    c_wake_monitor_test_script=""
    c_wake_monitor_gpio=12
    c_wake_monitor_debounce_ms=1000
}

get_params()
{
    case $# in
        0)  config_file="$default_config_file"
            ;;
        1)  case "$1" in
            -h) usage
                exit
                ;;
            -*) usage
                exit 1
                ;;
            esac
            config_file=$1
            ;;
        *) usage
            exit 1
            ;;
    esac

    if [ ! -r "$config_file" ]; then
        errmsg "Standby daemon config file '$config_file' not found"
        exit 1
    fi
}

host_shutdown()
{
    logmsg "Enter your host shutdown or hibernate commands here"
}

is_known_config_key()
{
    printf '%s\n' "$known_config_keys_cache" | grep -Fxq "$1"
}

get_config()
{
    while IFS= read -r line; do
        case "$line" in
            '' | '#'*) continue
            ;;
        esac

        key=$(echo "$line" | cut -d'=' -f1 -)
        raw_val=$(echo "$line" | cut -d'=' -f2 - | sed -e 's/ *#.*//')
        # Value with any quotes removed
        val=$(printf '%s' "$raw_val" | sed -e 's/^"\(.*\)"$/\1/')

        if ! is_known_config_key "$key"; then
            errmsg "Invalid config field: $key"
            exit 1
        fi

        if [ "$key" = "scan_ssid" ] && [ -n "$raw_val" ]; then
            case "$raw_val" in
                '"'*'"')
                    scan_ssid_hex=$(printf '%s' "$val" | hexdump -v -e '1/1 "%02x"')
                    ;;
                *)
                    case "$raw_val" in
                        *[!0-9a-fA-F]*)
                            errmsg "scan_ssid not quoted or contains non-hex characters"
                            exit 1
                            ;;
                    esac
                    if [ $(( ${#raw_val} % 2 )) -ne 0 ]; then
                        errmsg "scan_ssid must be a quoted string or even number of hex characters"
                        exit 1
                    fi
                    scan_ssid_hex="$raw_val"
                    ;;
            esac
        fi

        eval "c_$key=\$val"
    done < "$config_file"

    if $c_config_report; then
        c_verbose=true
    fi

    standby_config_file="$(dirname "$config_file")/$c_standby_config_file"
    if [ ! -r "$standby_config_file" ]; then
        errmsg "Config file for morse_cli standby '$standby_config_file' not found"
        exit 1
    fi

    dest_ip=$(sed -n -e 's/^dest_ip=\(.*\)$/\1/p' "$standby_config_file")
    if [ -z "$dest_ip" ]; then
        errmsg "morse_cli standby file '$standby_config_file' does not have a valid dest_ip"
        exit 1
    fi

    if [ -n "$c_wake_monitor_test_script" ]; then
        if $is_fullmac; then
            errmsg "Wake monitor test script not supported with FullMAC"
            exit 1
        fi

        if [ ! -x "$c_wake_monitor_test_script" ]; then
            errmsg "Wake monitor script ($c_wake_monitor_test_script) not found or not executable"
            exit 1
        fi
        logmsg -v "Test mode - "$c_wake_monitor_test_script" will be started after standby enter"
    fi
}

param_print_fmt="%-21s %-12s %s\n"

check_modparam()
{
    param=$1
    desc1=$2
    desc2=$3
    val=$(cat "/sys/module/morse/parameters/$1")

    printf "$param_print_fmt" "$param" "$val" "$desc1"
    if [ -n "$desc2" ]; then
        printf "$param_print_fmt" "" "" "$desc2"
    fi
}

check_standby_param()
{
    param=$1
    eval "val=\$c_$1"
    desc=$2

    if [ "${#val}" -gt 12 ]; then
        val=$(printf '%.9s...' "$val")
    fi

    printf "$param_print_fmt" "$param" "$val" "$desc"
}

config_report()
{
    fname="$standby_config_file"

    printf "\n"
    printf "$param_print_fmt" "Module parameter" "Value" "Behavior if not set"
    printf "$param_print_fmt" "----------------" "-----" "-------------------"
    if ! $is_fullmac; then
        check_modparam "enable_hw_scan" \
            "Standby mode is disabled" ""
    fi
    if ! $is_openwrt || ! $is_fullmac; then # Not supported on these platforms
        check_modparam "reattach_hw" \
            "Firmware will stop if the driver is unloaded" \
            "Firmware will have to be reloaded during restart"
    fi
    check_modparam "enable_dhcpc_offload" \
        "Standby status notifications will not be sent if IP addresses are not in $fname" \
        "Wake packets will not be received if no ARP entry on the AP"
    check_modparam "enable_arp_offload" \
        "The station will not respond to ARP requests or ICMP (ping) packets while in standby" \
        "The AP will not forward wake packets to the station if its ARP entry ages out"
    printf "\n"

    if ! $is_fullmac; then
        printf "$param_print_fmt" "Script parameter" "Value" "Behavior if not set"
        printf "$param_print_fmt" "----------------" "-----" "-------------------"
        check_standby_param "scan_ssid" "Standby can only be entered after association" ""
        printf "\n"
    fi

    c_host_power_on_pin=$(sed -n -e 's/^host_power_on_pin=\(.*\)$/\1/p' "$standby_config_file")
    printf "$param_print_fmt" "Standby parameter" "Value" "Behavior if not set"
    printf "$param_print_fmt" "-----------------" "-----" "-------------------"
    check_standby_param "host_power_on_pin" "Chip cannot wake the host" ""
    printf "\n"
}

# Save any existing ARP entries for the interface, for quick recovery on restart.
save_arp_entries()
{
    rm -f "$saved_arp_entries"

    awk ' /'"$c_interface"'$/ {
            if ($3 != 0)
                printf("%s %s\n", $1, $4)
        }' < /proc/net/arp > "$saved_arp_entries"
    sync
    logmsg -v "Stored $(grep -c '' "$saved_arp_entries") ARP entries"
}

# Save enough stuff to reconfigure the network using the DHCP client script, for quick recovery on
# restart.
save_dhcp_entries()
{
    if $is_fullmac; then
        # DHCP config can be obtained from the chip
        return
    fi

    rm -f "$saved_dhcp_entries"

    if_addr=$(ip -o -f inet address show dev "$c_interface" | \
        awk 'NR == 1 { print $4 }')

    ip_addr=${if_addr%/*}
    prefix_len=${if_addr#*/}

    if [ -n "$if_addr" ] && [ "$prefix_len" != "$if_addr" ]; then
        if [ "$prefix_len" -eq 0 ] 2>/dev/null; then
            netmask=0.0.0.0
        else
            mask=$(( (0xffffffff << (32 - prefix_len)) & 0xffffffff ))
            netmask=$(printf '%d.%d.%d.%d' \
                $(( (mask >> 24) & 255 )) \
                $(( (mask >> 16) & 255 )) \
                $(( (mask >> 8) & 255 )) \
                $(( mask & 255 )))
        fi
    else
        netmask=""
    fi

    router_addr=$(ip route show default dev "$c_interface" | \
        sed -n 's/default via \([0-9.]*\).*/\1/p' | \
        head -1)
    dns_addr=$(sed -n 's/nameserver \([0-9.]*\).*/\1/p' /etc/resolv.conf | \
        head -1)

    [ -n "$router_addr" ] || router_addr=0.0.0.0
    [ -n "$dns_addr" ] || dns_addr=0.0.0.0

    dhcp_entry=$(printf '%s %s %s %s %s' "$c_interface" "$ip_addr" "$netmask" "$router_addr" "$dns_addr")

    if [ -z "$ip_addr" ] || \
       [ -z "$netmask" ]; then
        logmsg -v "DHCP entry incomplete - not stored: $dhcp_entry"
        return
    fi

    printf '%s %s %s %s %s\n' \
        "$c_interface" \
        "$ip_addr" \
        "$netmask" \
        "$router_addr" \
        "$dns_addr" > "$saved_dhcp_entries"
    sync

    logmsg -v "Stored DHCP entry: $saved_dhcp_entries"
}

# Make sure there can only be one copy of this daemon running
kill_old_daemon()
{
    for cmdline in /proc/[0-9]*/cmdline; do
        pid=${cmdline#/proc/}
        pid=${pid%/cmdline}

        if [ "$pid" = "$$" ]; then
            continue
        fi

        if [ ! -r "$cmdline" ]; then
            continue
        fi

        if tr '\0' '\n' < "$cmdline" 2>/dev/null | grep -wq "$procname"; then
            logmsg -v "Stopping previous version of daemon (pid $pid)"
            kill -TERM "$pid" 2>/dev/null
        fi
    done
}

# Restore saved ARP entries after a restart
restore_arp_entries()
{
    if [ -r "$saved_arp_entries" ]; then
        while IFS= read -r entry; do
            set -- $entry
            if $is_fullmac; then
                docmd arp -i $c_interface -s "$1" "$2"
            else
                docmd ip neigh replace "$1" lladdr "$2" dev "$c_interface" nud permanent
            fi
        done < "$saved_arp_entries"
        # 'grep -c' is more portable than wc
        count=$(grep -c '' "$saved_arp_entries")

    else
        count=0
    fi
    logmsg -v "Restored $count ARP entries"
}

# Restore saved DHCP entries after a restart
restore_dhcp_entries()
{
    echo "nameserver 8.8.8.8" >/etc/resolv.conf

    if [ ! -x dhcpc_update.sh ]; then
        errmsg "save_dhcp_entries is set but dhcpc_update.sh not found"
        exit 1
    fi

    if $is_fullmac; then
        MORSE_CMD_DHCP_RETCODE_ALREADY_ENABLED=2
        morse_cli dhcpc enable
        if [ $? -eq "$MORSE_CMD_DHCP_RETCODE_ALREADY_ENABLED" ]; then
            morse_cli dhcpc update
        fi
        return
    fi

    touch "$saved_dhcp_entries"
    set -- $(cat "$saved_dhcp_entries")
    if [ $# -eq 5 ]; then
        docmd ./dhcpc_update.sh "$@"
    else
        logmsg -v "No valid DHCP entry to restore"
    fi
}

init()
{
    if ! device_status=$(iw dev "$c_interface" link 2>/dev/null); then
        logmsg -v "Waiting for device $c_interface"
        return 1
    fi

    if $c_save_arp_entries; then
        restore_arp_entries
    fi

    if $c_save_dhcp_entries; then
        restore_dhcp_entries
    fi

    # Make sure the firmware is not already in standby
    if ! morse_cli -i "$c_interface" standby exit >/dev/null; then
        errmsg "Failed to reset standby mode"
        return 1
    fi

    if ! docmd morse_cli -i "$c_interface" standby config "$standby_config_file"; then
        errmsg "Failed to configure standby mode"
        return 1
    fi
}

# Enter standby mode
standby_enter()
{
    # Tell the chip to enter standby mode. This also disables all normal traffic to/from the chip.
    if ! docmd morse_cli -i "$c_interface" standby enter; then
        # This can fail if the hardware is currently scanning
        return 1
    fi

    if $c_save_arp_entries; then
        save_arp_entries
    fi

    if $c_save_dhcp_entries; then
        save_dhcp_entries
    fi

    if [ -z "$c_wake_monitor_test_script" ]; then
        host_shutdown
    else
        logmsg "Starting wake monitor test script..."
        . "$c_wake_monitor_test_script"
    fi

    logmsg -v "Done"
    exit
}

# Issue a warning if security is not enabled
check_security()
{
    if $is_fullmac; then
        return
    fi

    if wpa_cli_s1g -i "$c_interface" status 2>/dev/null | grep -q "pairwise_cipher=NONE"; then
        logmsg -v "Security is disabled - wake packets will be ignored"
    fi
}

# Monitor packet counters and return after a configured period of inactivity.
monitor_traffic()
{
    associated=false
    not_assoc_poll_periods=0
    rx_bytes=0
    tx_bytes=0
    rx_bytes_prev=0
    tx_bytes_prev=0

    logmsg "Monitoring $c_interface activity..."
    while :; do
        sleep "$c_poll_period"

        if ! device_status=$(iw dev "$c_interface" link 2>/dev/null); then
            logmsg -v "Waiting for device $c_interface"
            continue
        fi

        # This test serves to check if associated on all supported platforms
        if echo "$device_status" | grep -q "SSID:"; then
            if ! $associated; then
                associated=true
                not_assoc_poll_periods=0
                check_security
            fi
        else
            associated=false
            not_assoc_poll_periods=$((not_assoc_poll_periods + 1))

            # If not associated, only enter standby if scan_ssid is configured (so the chip can scan
            # for beacons and wake to associate when seen).
            if [ -z "$c_scan_ssid" ]; then
                logmsg -v "Waiting for association - SSID not configured"
                continue
            fi

            if [ "$not_assoc_poll_periods" -lt "$c_not_assoc_poll_periods" ]; then
                logmsg -v "Waiting for association - attempt $not_assoc_poll_periods"
                continue
            fi
        fi

        if $associated; then
            # ifconfig provides Tx and Rx counters on all supported platforms
            if ! output=$(ifconfig "$c_interface"); then
                logmsg -v "Waiting for interface $c_interface"
                continue
            fi
            rx_bytes=$(echo $output | sed -r 's/.*RX packets:[^0-9]*([0-9]*).*/\1/')
            tx_bytes=$(echo $output | sed -r 's/.*TX packets:[^0-9]*([0-9]*).*/\1/')
            if [ -z "$rx_bytes" ] || [ -z "$tx_bytes" ]; then
                errmsg "Waiting for valid ifconfig output"
                continue
            fi
            logmsg -v "Rx:$rx_bytes Tx:$tx_bytes"
            if [ "$rx_bytes" -ne "$rx_bytes_prev" ] || [ "$tx_bytes" -ne "$tx_bytes_prev" ]; then
                # Traffic detected
                rx_bytes_prev=$rx_bytes
                tx_bytes_prev=$tx_bytes
                continue
            fi
        elif ! $is_fullmac; then
            # Disable network to ensure a scan is not already in progress, then scan to ensure
            # the chip has the configured SSID.
            docmd wpa_cli_s1g -i "$c_interface" disable_network "$c_scan_ssid"
            if ! docmd wpa_cli_s1g -i "$c_interface" scan ssid "$scan_ssid_hex"; then
                logmsg -v "Waiting for 'wpa_cli_s1g scan ssid' command to succeed"
                continue
            fi
            # Wait for scan to complete - adjust time to suit your scan configuration
            docmd sleep 5
        fi

        if $associated; then
            msg="no data traffic for $c_poll_period seconds"
        else
            msg="no association for $((c_poll_period * c_not_assoc_poll_periods)) seconds"
        fi
        logmsg -v "Entering standby mode - $msg"
        if ! standby_enter; then
            # Standby was not entered - re-evaluate at next poll period
            errmsg "Did not enter standby mode - continuing"
        fi

    done
}

init_config

get_params "$@"

known_config_keys_cache=$(known_config_keys)

get_config

kill_old_daemon
trap 'exit 0' INT TERM HUP QUIT

# Initialization should not fail, but keep trying if it does, for maximum reliability.
while ! init; do
    errmsg "Standby initialization incomplete - retrying in 5 seconds"
    sleep 5
done

if $c_config_report; then
    config_report
fi

monitor_traffic

errmsg "Completed unexpectedly"
