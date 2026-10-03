# Lattice ECP5 flow: Yosys (synth_ecp5) -> nextpnr-ecp5 -> ecppack (Project Trellis)
#
# Board file must define: DEVICE (e.g. 85k, um5g-85k), PACKAGE (e.g. CABGA381), OFL_BOARD
# Project file may set:   LPF (default constr/$(BOARD).lpf), NEXTPNR_FLAGS

LPF ?= constr/$(BOARD).lpf
CONSTR := $(PROJDIR)/$(LPF)

SYNTH_JSON := $(BUILD)/$(TOP).synth.json
CONFIG     := $(BUILD)/$(TOP).config
BITSTREAM  := $(BUILD)/$(TOP).bit

synth: $(SYNTH_JSON)
pnr: $(CONFIG)
bitstream: $(BITSTREAM)

$(SYNTH_JSON): $(RTL)
	@mkdir -p $(dir $@)
	$(RUN) yosys -q -l $(BUILD)/yosys.log \
	  -p "read_verilog -sv $(DEFINES) $(RTL); synth_ecp5 -top $(TOP) -json $@"

$(CONFIG): $(SYNTH_JSON) $(CONSTR)
	$(RUN) nextpnr-ecp5 -q -l $(BUILD)/nextpnr.log \
	  --$(DEVICE) --package $(PACKAGE) --freq $(CLK_MHZ) --json $< --lpf $(CONSTR) --textcfg $@ $(NEXTPNR_FLAGS)

$(BITSTREAM): $(CONFIG)
	$(RUN) ecppack $< $@
