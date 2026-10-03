# OSS FPGA development flow (Yosys / nextpnr / Apicula / openFPGALoader)
#
#   make setup                      # build the pinned Nix toolchain (first time)
#   make                            # = make bitstream for default BOARD/PROJECT
#   make sim lint                   # simulate (Icarus) / lint (Verilator)
#   make prog                       # load bitstream to SRAM (volatile)
#   make flash                      # write bitstream to SPI flash (persistent)
#   make BOARD=tangnano9k PROJECT=blinky bitstream
#
# Every tool runs inside `nix develop`, so the host only needs Nix and make.

BOARD   ?= tangnano9k
PROJECT ?= blinky

ROOT    := $(patsubst %/,%,$(dir $(abspath $(firstword $(MAKEFILE_LIST)))))
BUILD   := $(ROOT)/build/$(PROJECT)/$(BOARD)
PROJDIR := $(ROOT)/projects/$(PROJECT)

# ---------------------------------------------------------------- Nix wrapper
NIX       ?= $(shell command -v nix 2>/dev/null || echo /nix/var/nix/profiles/default/bin/nix)
NIX_FLAGS := --extra-experimental-features 'nix-command flakes'
ifeq ($(FPGA_ENV),nix)
  RUN :=
else
  RUN := $(NIX) $(NIX_FLAGS) develop $(ROOT) --command
endif

# ------------------------------------------------- board / project / arch flow
include $(ROOT)/boards/$(BOARD).mk
include $(PROJDIR)/project.mk
include $(ROOT)/mk/arch-$(ARCH).mk

# Project files are relative to the project directory.
RTL := $(addprefix $(PROJDIR)/,$(RTL_SRCS))
TB  := $(addprefix $(PROJDIR)/,$(TB_SRCS))

# Board facts exposed to RTL as `defines (designs fall back to their own defaults).
DEFINES := -DCLK_HZ=$(CLK_HZ) $(if $(LED_COUNT),-DLED_COUNT=$(LED_COUNT))
# Timing target for nextpnr, derived from the board clock.
CLK_MHZ := $(shell awk 'BEGIN { print $(CLK_HZ) / 1000000 }')

WAVE_VIEWER ?= surfer

.DEFAULT_GOAL := bitstream
# Never keep half-written outputs (e.g. the VCD of a failed simulation).
.DELETE_ON_ERROR:
.PHONY: help setup nix-check versions shell update lint sim wave synth pnr \
        bitstream prog flash detect clean distclean

help:
	@echo "Targets:"
	@echo "  setup      build the pinned toolchain (needs Nix) and print versions"
	@echo "  versions   print tool versions"
	@echo "  shell      open a shell with all tools (or use direnv: .envrc)"
	@echo "  update     update flake.lock (bump all tool versions)"
	@echo "  lint       Verilator lint of RTL"
	@echo "  sim        Icarus Verilog self-checking testbench -> VCD"
	@echo "  wave       open VCD in WAVE_VIEWER (surfer|gtkwave, now: $(WAVE_VIEWER))"
	@echo "  synth/pnr/bitstream   build steps ($(ARCH) flow)"
	@echo "  detect     detect the FPGA over JTAG"
	@echo "  prog       load bitstream into SRAM (lost on power off)"
	@echo "  flash      write bitstream into SPI flash (persistent)"
	@echo "  clean      remove build/$(PROJECT)/$(BOARD)"
	@echo "Variables: BOARD=$(BOARD) PROJECT=$(PROJECT)"

# ------------------------------------------------------------------ toolchain
nix-check:
	@test -x "$(NIX)" || { \
	  echo "Nix is not installed. Install upstream (OSS) Nix, then re-run 'make setup':"; \
	  echo "  sh <(curl --proto '=https' --tlsv1.2 -sSfL https://nixos.org/nix/install) --daemon"; \
	  exit 1; }

setup: nix-check
	$(NIX) $(NIX_FLAGS) flake lock $(ROOT)
	$(RUN) true
	@$(MAKE) --no-print-directory versions

versions:
	@$(RUN) sh -c '\
	  echo "yosys          : $$(yosys -V)"; \
	  echo "nextpnr        : $$(nextpnr-himbaechel --version 2>&1 | head -1)"; \
	  echo "apycula        : $$(python3 -c "import importlib.metadata as m; print(m.version(\"Apycula\"))")"; \
	  echo "openFPGALoader : $$(openFPGALoader --Version 2>&1 | head -1)"; \
	  echo "iverilog       : $$(iverilog -V 2>&1 | head -1)"; \
	  echo "verilator      : $$(verilator --version)"; \
	  echo "surfer         : $$(command -v surfer >/dev/null && surfer --version || echo n/a)"; \
	  echo "gtkwave        : $$(command -v gtkwave >/dev/null && gtkwave --version 2>/dev/null | head -1 || echo n/a)"'

shell: nix-check
	$(NIX) $(NIX_FLAGS) develop $(ROOT)

update: nix-check
	$(NIX) $(NIX_FLAGS) flake update --flake $(ROOT)

# ------------------------------------------------------------- verification
lint:
	$(RUN) verilator --lint-only -Wall $(DEFINES) --top-module $(TOP) $(RTL)

sim: $(BUILD)/sim/$(TB_TOP).vcd

$(BUILD)/sim/$(TB_TOP).vvp: $(RTL) $(TB)
	@mkdir -p $(dir $@)
	$(RUN) iverilog -g2012 -Wall -s $(TB_TOP) -o $@ $^

# The testbench calls $fatal on failure, which makes vvp exit non-zero.
$(BUILD)/sim/$(TB_TOP).vcd: $(BUILD)/sim/$(TB_TOP).vvp
	$(RUN) vvp -n $< +vcd=$@

wave: $(BUILD)/sim/$(TB_TOP).vcd
	$(RUN) $(WAVE_VIEWER) $<

# ------------------------------------------------------------------ hardware
detect:
	$(RUN) openFPGALoader -b $(OFL_BOARD) --detect

prog: $(BITSTREAM)
	$(RUN) openFPGALoader -b $(OFL_BOARD) $<

flash: $(BITSTREAM)
	$(RUN) openFPGALoader -b $(OFL_BOARD) -f $<

clean:
	rm -rf $(BUILD)

distclean:
	rm -rf $(ROOT)/build
