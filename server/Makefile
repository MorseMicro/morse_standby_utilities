# Copyright 2020-2026 Morse Micro

TARGETS = morse_standby_monitor morse_standby_wake
SOURCE_DIR = source
BUILD_DIR = build
BUILD_TARGETS = $(addprefix $(BUILD_DIR)/,$(TARGETS))

BOARD ?= rpi4b-buildroot

ifeq ($(BOARD),rpi4b-buildroot)
CC = arm-linux-gnueabihf-gcc
else ifeq ($(BOARD),rpi4b-openwrt)
CC = aarch64-linux-musl-gcc
else
$(error Unknown BOARD '$(BOARD)'. Supported values: rpi4b-buildroot, rpi4b-openwrt)
endif

CFLAGS = -g -Wall -Werror -I..

ifeq ($(V),1)
Q =
else
Q = @
endif

.PHONY: all clean

all: $(BUILD_TARGETS)

$(BUILD_DIR):
	@echo "MKDIR $@"
	$(Q)mkdir -p $@

$(BUILD_DIR)/%.o: $(SOURCE_DIR)/%.c | $(BUILD_DIR)
	@echo "CC    $@"
	$(Q)$(CC) -c -o $@ $< $(CFLAGS)

$(BUILD_DIR)/morse_standby_monitor: $(SOURCE_DIR)/morse_standby_monitor.c | $(BUILD_DIR)
	@echo "LD    $@"
	$(Q)$(CC) -o $@ $^ $(CFLAGS)

$(BUILD_DIR)/morse_standby_wake: $(SOURCE_DIR)/morse_standby_wake.c | $(BUILD_DIR)
	@echo "LD    $@"
	$(Q)$(CC) -o $@ $^ $(CFLAGS)

clean:
	@echo "CLEAN $(BUILD_DIR)"
	$(Q)rm -rf $(BUILD_DIR)
