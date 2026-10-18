# SPDX-License-Identifier: GPL-2.0
#
# Makefile for GC2607 V4L2 driver (out-of-tree build)
#

# Module name
obj-m := gc2607.o

# Kernel headers directory (auto-detect running kernel)
KDIR ?= /lib/modules/$(shell uname -r)/build

# Build directory
PWD := $(shell pwd)

# Userspace ISP program
ISP_SRC := gc2607_isp.c
ISP_BIN := gc2607_isp
CC_USER ?= gcc
CFLAGS_USER ?= -O2 -Wall -Wextra -march=native

# Default target: build the module and ISP
all: modules isp

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

isp: $(ISP_BIN)

$(ISP_BIN): $(ISP_SRC)
	$(CC_USER) $(CFLAGS_USER) -o $@ $< -lm

# Developer tools and unit tests; binaries go to build/, which git ignores.
BUILD := build
TEST_SRCS := $(wildcard tests/test_*.c)
TEST_BINS := $(patsubst tests/%.c,$(BUILD)/%,$(TEST_SRCS))

$(BUILD):
	mkdir -p $@

# Per-frame ISP timing on a performance, an efficiency and a low-power core of this laptop
# (cpus 0, 12, 20; `lscpu -e`). See docs/reviews/2026-10-18-camera-fix-handover.md.
$(BUILD)/bench_isp: tools/bench_isp.c tools/bench_common.h $(ISP_SRC) | $(BUILD)
	$(CC_USER) $(CFLAGS_USER) -Wno-unused-function -o $@ tools/bench_isp.c -lm

# Frames-until-a-control-change-applies probe, run by gc2607-raw-capture.sh --latency.
$(BUILD)/ae_latency: tools/ae_latency.c | $(BUILD)
	$(CC_USER) $(CFLAGS_USER) -o $@ $< -lm

# Offline replay of one raw frame through the ISP, used by tools/isp_metrics.py.
$(BUILD)/isp_replay: tools/isp_replay.c $(ISP_SRC) | $(BUILD)
	$(CC_USER) $(CFLAGS_USER) -Wno-unused-function -o $@ tools/isp_replay.c -lm

bench: $(BUILD)/bench_isp
	@for c in 0 12 20; do echo "== cpu $$c"; taskset -c $$c ./$(BUILD)/bench_isp; done

# Unit tests include gc2607_isp.c directly, so they can reach its static functions.
$(BUILD)/test_%: tests/test_%.c $(ISP_SRC) | $(BUILD)
	$(CC_USER) $(CFLAGS_USER) -Wno-unused-function -o $@ $< -lm

test: $(TEST_BINS)
	@set -e; for t in $(TEST_BINS); do echo "== $$t"; ./$$t; done

# Install module to system
install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

# Clean build artifacts
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f Module.symvers modules.order $(ISP_BIN)
	rm -rf $(BUILD)

# Help target
help:
	@echo "GC2607 V4L2 Driver Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Build kernel module and userspace ISP (default)"
	@echo "  modules  - Build only the gc2607.ko kernel module"
	@echo "  isp      - Build only the gc2607_isp userspace program"
	@echo "  install  - Build and install module to system (requires sudo)"
	@echo "  test     - Build and run the ISP unit tests (tests/test_*.c)"
	@echo "  bench    - Time the ISP per frame on three core types"
	@echo "  clean    - Remove all build artifacts"
	@echo "  help     - Show this help message"
	@echo ""
	@echo "Current kernel: $(shell uname -r)"
	@echo "Kernel headers: $(KDIR)"
	@echo ""
	@echo "Testing commands:"
	@echo "  sudo insmod gc2607.ko          - Load the driver"
	@echo "  dmesg | grep gc2607            - Check driver messages"
	@echo "  sudo rmmod gc2607              - Unload the driver"
	@echo "  lsmod | grep gc2607            - Check if module is loaded"

.PHONY: all modules isp install clean help bench test
