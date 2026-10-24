/*
 * Copyright 2022-2026 Morse Micro
 * SPDX-License-Identifier: MIT
 *
 * Utility to monitor standby status notification packets from Morse Micro devices that are in
 * Standby mode.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <getopt.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <arpa/inet.h>

#define STANDBY_FRAME_TYPE                  (1)
#define STANDBY_FRAME_MAX_USER_PAYLOAD_LEN  (64)
#define STANDBY_BUFLEN  (sizeof(struct standby_frame_content) + STANDBY_FRAME_MAX_USER_PAYLOAD_LEN)
#define STANDBY_IPADDR_LEN                  (20)
#define STANDBY_CFG_DFLT_PORT               (22000)
#define TIME_STR_LEN                        (24)

/** Morse Micro OUI */
const uint8_t morse_oui[3] = {0x0C, 0xBF, 0x74};

/** Server configuration */
struct server_cfg {
    struct in_addr ipaddr;
    uint16_t port;
};

/** Station state */
enum standby_frame_value {
    /** Station is not in standby mode */
    STANDBY_FRAME_VALUE_AWAKE    = 0x00,
    /** Station is in standby mode. */
    STANDBY_FRAME_VALUE_STANDBY  = 0x01,
    /** Station is in the process of leaving standby mode */
    STANDBY_FRAME_VALUE_WAKEUP   = 0x02,
};

/** Structure of UDP-based standby status notification packets */
struct standby_frame_content {
    /** Morse Micro OUI */
    uint8_t mm_oui[3];
    /** Frame type (will be set to STANDBY_FRAME_TYPE) */
    uint8_t type;
    /** Standby state (from enum standby_frame_value) */
    uint8_t value;
    /** User-configured content */
    uint8_t payload[0];
};

static bool running = true;
static struct server_cfg cfg = {
    .ipaddr = { 0 },
    .port = STANDBY_CFG_DFLT_PORT
};
static int server_sock = -1;

static void report_standby_status(int sock, struct sockaddr_in *sock_addr, uint32_t sock_size)
{
    int n;
    char buf[STANDBY_BUFLEN];
    struct standby_frame_content *frame = (struct standby_frame_content *) &buf[0];

    while (running)
    {
        memset(buf, 0, sizeof(buf));

        n = recvfrom(sock, &buf[0], sizeof(buf),
            0, (struct sockaddr *) sock_addr, &sock_size);

        if (n >= sizeof(*frame) &&
            memcmp(&frame->mm_oui, &morse_oui, sizeof(morse_oui)) == 0 &&
            frame->type == STANDBY_FRAME_TYPE &&
            (frame->value == STANDBY_FRAME_VALUE_AWAKE ||
             frame->value == STANDBY_FRAME_VALUE_STANDBY))
        {
            char time_buf[TIME_STR_LEN];
            const time_t now_ts = time(NULL);
            struct tm ts_s;

            if (localtime_r(&now_ts, &ts_s) == NULL)
                continue;

            strftime(time_buf, TIME_STR_LEN, "%Y-%m-%d %H:%M:%S", &ts_s);
            printf("%s %s %s",
                time_buf,
                inet_ntoa(((struct sockaddr_in *)sock_addr)->sin_addr),
                (frame->value == STANDBY_FRAME_VALUE_AWAKE) ? "awake  " : "standby");

            /* print user content */
            if (n > sizeof(*frame))
            {
                printf(" 0x");
                for (int i = 0; i < (n - sizeof(*frame)); i++)
                {
                    printf("%x", frame->payload[i]);
                }
            }

            printf("\n");
        }
    }
}

static int standby_recv(void)
{
    int ret = 0;
    struct sockaddr_in server_addr;

    server_sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (server_sock < 0)
    {
        printf("Socket creation failed\n");
        ret = -1;
        goto exit;
    }

    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(cfg.port);
    server_addr.sin_addr = cfg.ipaddr;

    if (bind(server_sock, (struct sockaddr *) &server_addr, sizeof(server_addr)) < 0)
    {
        printf("Bind to port %u failed\n", cfg.port);
        ret = -1;
        goto exit;
    }

    printf("Listening for incoming standby status notification packets on (%u)\n", cfg.port);
    report_standby_status(server_sock, &server_addr, sizeof(server_addr));

exit:
    if (server_sock >= 0)
    {
        if (close(server_sock) < 0)
            perror("close");

        printf("Socket closed\n");
    }

    return ret;
}

void standby_sigend_handler(int signal)
{
    printf("Terminating due to signal\n");
    running = false;
}

static void usage(void)
{
    printf("Usage: morse_standby_monitor [OPTION]...\n");
    printf("Start the standby monitor, to monitor the state of associated Morse Micro devices "
           "that are configured for standby mode.\n\n");

    printf("    -s <server IP address>    IP address on which to listen for status packets"
           " (default:IPADDR_ANY)\n");
    printf("    -p <server port>          UDP port on which to to listen for status packets"
           " (default:%d)\n", STANDBY_CFG_DFLT_PORT);
    printf("    -h                        display this help and exit\n");
}

static int parse_args(int argc, char **argv)
{
    int flag;

    while ((flag = getopt(argc, argv, "s:p:h")) != -1)
    {
        switch (flag)
        {
            case 's':
                if (inet_pton(AF_INET, optarg, &cfg.ipaddr) != 1)
                {
                    printf("Invalid IPv4 address %s\n", optarg);
                    usage();
                    exit(-1);
                }
                break;
            case 'p':
                cfg.port = atoi(optarg);
                break;
            case 'h':
                usage();
                exit(0);
                break;
            default:
                printf("Unsupported parameter %s\n", optarg);
                usage();
                exit(-1);
                break;
        }
    }

    return 0;
}

int main(int argc, char **argv)
{
    struct sigaction sa = {0};

    sa.sa_handler = standby_sigend_handler;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    cfg.port = STANDBY_CFG_DFLT_PORT;

    if (parse_args(argc, argv) < 0)
        exit(-1);

    return standby_recv();
}
