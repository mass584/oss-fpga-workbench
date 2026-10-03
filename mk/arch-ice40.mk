# Lattice iCE40 flow: Yosys (synth_ice40) -> nextpnr-ice40 -> icepack (IceStorm)
#
# Board file must define: DEVICE (e.g. up5k), PACKAGE (e.g. sg48), OFL_BOARD
# Project file may set:   PCF (default constr/$(BOARD).pcf), NEXTPNR_FLAGS

PCF ?= constr/$(BOARD).pcf
CONSTR := $(PROJDIR)/$(PCF)

SYNTH_JSON := $(BUILD)/$(TOP).synth.json
ASC        := $(BUILD)/$(TOP).asc
BITSTREAM  := $(BUILD)/$(TOP).bin

synth: $(SYNTH_JSON)
pnr: $(ASC)
bitstream: $(BITSTREAM)

$(SYNTH_JSON): $(RTL)
	@mkdir -p $(dir $@)
	$(RUN) yosys -q -l $(BUILD)/yosys.log \
	  -p "read_verilog -sv $(DEFINES) $(RTL); synth_ice40 -top $(TOP) -json $@"

$(ASC): $(SYNTH_JSON) $(CONSTR)
	$(RUN) nextpnr-ice40 -q -l $(BUILD)/nextpnr.log \
	  --$(DEVICE) --package $(PACKAGE) --freq $(CLK_MHZ) --json $< --pcf $(CONSTR) --asc $@ $(NEXTPNR_FLAGS)

$(BITSTREAM): $(ASC)
	$(RUN) icepack $< $@
