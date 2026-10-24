/*
 * Copyright 2022-2026 Morse Micro
 * SPDX-License-Identifier: MIT
 *
 * Utility to send a UDP wake packet to a Morse Micro device that is in standby mode.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <getopt.h>
#include <limits.h>
#include <sys/socket.h>
#include <arpa/inet.h>

/* Max UDP packet length, leaving room for Ethernet, IPv4 and UDP headers */
#define STANDBY_FRAME_MAX_DATA_LEN          (1500 - 14 - 20 - 8)
#define STANDBY_CFG_DFLT_PORT               (22000)
#define STANDBY_FRAME_MAX_USER_PATTERN_LEN  (64)
#define STANDBY_CFG_DFLT_WAKE_PATTERN       "0cbf740102"
#define STANDBY_CFG_DFLT_WAKE_PATTERN_OFFSET (0)

struct cfg_s {
    struct in_addr ipaddr;
    uint16_t port;
    char data[STANDBY_FRAME_MAX_DATA_LEN];
    size_t data_len;
};

struct cfg_s cfg = {
    .ipaddr = { 0 },
    .port = STANDBY_CFG_DFLT_PORT,
    .data = "",
    .data_len = STANDBY_CFG_DFLT_WAKE_PATTERN_OFFSET
};

static void usage(void)
{
    printf(
        "Usage: morse_standby_wake [OPTION]... IP_ADDRESS\n"
        "Send a UDP wake packet to a Morse Micro device that is in standby mode.\n\n"
        "-p <port>        UDP port on which to send the wake packet (default %u)\n"
        "-P <hex string>  user-specified pattern used to verify the wake request by the receiving\n"
        "                 station (default %s [Morse Micro OUI, Standby (0x01), Wakeup (0x02)])\n"
        "-o <offset>      Offset from start of payload to insert the pattern (default %u)\n"
        "-h               Display this help and exit\n",
     STANDBY_CFG_DFLT_PORT, STANDBY_CFG_DFLT_WAKE_PATTERN, STANDBY_CFG_DFLT_WAKE_PATTERN_OFFSET);
}

static int hex2num(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;

    return -1;
}

static int hex2byte(const char *hex)
{
    int a, b;

    a = hex2num(*hex++);
    if (a < 0)
        return -1;
    b = hex2num(*hex++);
    if (b < 0)
        return -1;

    return (a << 4) | b;
}

int hexstr2bin(const char *hex, char *buf, size_t len)
{
    size_t i;
    int a;
    const char *ipos = hex;
    char *opos = buf;

    for (i = 0; i < len; i++)
    {
        a = hex2byte(ipos);
        if (a < 0)
            return -1;
        *opos++ = a;
        ipos += 2;
    }

    return 0;
}

static int send_pkt(void)
{
    int s;
    struct sockaddr_in sa;
    int ret;

    s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0)
    {
        printf("Failed to create socket\n");
        return -1;
    }
    sa.sin_family = AF_INET;
    sa.sin_addr = cfg.ipaddr;
    sa.sin_port = htons(cfg.port);

    ret = sendto(s, cfg.data, cfg.data_len, 0, (struct sockaddr *) &sa, sizeof(sa));
    if (ret < 0)
    {
        printf("Failed to send wake-up packet\n");
        return -1;
    }

    return 0;
}

static int parse_args(int argc, char **argv)
{
    int flag;
    char *payload_hex = STANDBY_CFG_DFLT_WAKE_PATTERN;
    size_t payload_len;
    size_t offset = 0;
    uint16_t port = 0;

    while ((flag = getopt(argc, argv, "p:P:o:h")) != -1)
    {
        switch (flag)
        {
            case 'p':
            {
                uint32_t parsed;

                errno = 0;
                parsed = (uint32_t) strtoul(optarg, NULL, 0);
                if ((errno != 0) || (parsed == 0) || (parsed > USHRT_MAX))
                {
                    printf("Invalid port %s\n", optarg);
                    return -EINVAL;
                }
                port = (uint16_t) parsed;
                cfg.port = port;
                break;
            }
            case 'P':
                payload_hex = optarg;
                break;
            case 'o':
            {
                uint32_t parsed;

                errno = 0;
                parsed = (uint32_t) strtoul(optarg, NULL, 0);
                if ((errno != 0) || (parsed > USHRT_MAX))
                {
                    printf("Invalid offset %s\n", optarg);
                    return -EINVAL;
                }
                offset = (size_t) parsed;
                break;
            }
            case 'h':
                usage();
                return 0;
            default:
                printf("Unsupported parameter %s\n", optarg);
                usage();
                return -EINVAL;
        }
    }

    if (optind != (argc - 1))
    {
        usage();
        return -EINVAL;
    }

    if (inet_pton(AF_INET, argv[optind], &cfg.ipaddr) != 1)
    {
        printf("Invalid IPv4 address %s\n", argv[optind]);
        return -EINVAL;
    }

    payload_len = strlen(payload_hex) / 2;
    if (payload_len > STANDBY_FRAME_MAX_USER_PATTERN_LEN)
    {
        printf("Invalid IPv4 address %s\n", argv[optind]);
        return -EINVAL;
    }

    cfg.data_len = offset + payload_len;
    if ((cfg.data_len) > sizeof(cfg.data))
    {
        printf("Packet payload is too long (have %zd bytes, max %zd)\n",
            cfg.data_len, sizeof(cfg.data));
        return -EINVAL;
    }

    if ((strlen(payload_hex) & 1) ||
        (hexstr2bin(payload_hex, cfg.data + offset, payload_len) < 0))
    {
        printf("Invalid hex string\n");
        return -EINVAL;
    }

    return 0;
}

int main(int argc, char **argv)
{
    int ret;

    ret = parse_args(argc, argv);
    if (ret < 0)
        return ret;

    ret = send_pkt();

    return ret;
}
