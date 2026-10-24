# Morse Standby Utilities

Utilities and sample configuration for using Morse Micro standby mode.

This repository contains:

- `station/`: sample station-side standby daemon scripts and configuration files.
- `server/`: host-side utilities for monitoring standby status packets and for sending wake packets.

## Station Scripts and Configuration Files

The station-side script is `station/scripts/morse_standby_daemon.sh`. It configures standby mode on
a Morse Micro interface, monitors interface activity, and enters standby after the configured idle
period.

The daemon takes two configuration files as input:

- `station/config/morse_standby_daemon.conf`: input to `morse_standby_daemon.sh`
- `station/config/standby.conf`: input to `morse_cli standby config`, invoked by the daemon

The wake monitor script is purely a development aid:

- `station/scripts/morse_standby_wake_monitor.sh`: sourced by `morse_standby_daemon.sh` in test
  mode. It inherits the daemon's functions and variables, monitors the host wake GPIO, and
  emulates host restart when the chip toggles the wake pin. The host device cannot actually be shut
  down or put into hibernation while it is running.


During development, the daemon can be run in the foreground with reporting enabled. For production,
configure it to run in the background with debug output disabled.

Refer to the comments in the configuration files for the supported options and defaults.

## Server Utilities

### Build the Server Utilities

Build from the `server` directory:

```sh
make -C server
```

This creates:

- `server/build/morse_standby_monitor`
- `server/build/morse_standby_wake`

Remove generated files with:

```sh
make -C server clean
```

The Makefile defaults to the `rpi4b-buildroot` board profile. Select a different compiler with
`BOARD`:

```sh
make -C server BOARD=rpi4b-openwrt
```

Use `V=1` to show the full build commands:

```sh
make -C server V=1
```

Supported board values are:

- `rpi4b-buildroot`
- `rpi4b-openwrt`

### Monitor Standby Status

`morse_standby_monitor` listens for UDP standby status frames from configured stations.

```sh
server/build/morse_standby_monitor
```

Common options:

```sh
server/build/morse_standby_monitor -s <server-ip> -p <udp-port>
```

If the server IP address is not configured, the monitor listens on all interfaces.

The default UDP port is `22000`.

### Send a Wake Packet

`morse_standby_wake` sends a UDP wake packet to a station in standby mode.

```sh
server/build/morse_standby_wake <station-ip>
```

Common options:

```sh
server/build/morse_standby_wake -p <udp-port> -P <hex-pattern> -o <offset> <station-ip>
```

The default wake pattern is `0cbf740102` (Morse Micro OUI: 0x0cbf74, Standby: 0x01, Wakeup: 0x02)
and the default UDP port is `22000`.

## Licence

Copyright 2022-2026 Morse Micro. Released under the [MIT Licence](LICENCE).
