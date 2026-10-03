# Gowin flow: Yosys (synth_gowin) -> nextpnr-himbaechel (gowin uarch) -> gowin_pack (Apicula)
#
# Board file must define: DEVICE (part number), FAMILY (Apicula family name),
#                         OFL_BOARD (openFPGALoader -b name)
# Project file may set:   CST (constraint file, default constr/$(BOARD).cst), NEXTPNR_FLAGS

GOWIN_SYNTH_FAMILY ?= gw1n
CST ?= constr/$(BOARD).cst
CONSTR := $(PROJDIR)/$(CST)

SYNTH_JSON := $(BUILD)/$(TOP).synth.json
PNR_JSON   := $(BUILD)/$(TOP).pnr.json
BITSTREAM  := $(BUILD)/$(TOP).fs

synth: $(SYNTH_JSON)
pnr: $(PNR_JSON)
bitstream: $(BITSTREAM)

$(SYNTH_JSON): $(RTL)
	@mkdir -p $(dir $@)
	$(RUN) yosys -q -l $(BUILD)/yosys.log \
	  -p "read_verilog -sv $(DEFINES) $(RTL); synth_gowin -family $(GOWIN_SYNTH_FAMILY) -top $(TOP) -json $@"

$(PNR_JSON): $(SYNTH_JSON) $(CONSTR)
	$(RUN) nextpnr-himbaechel -q -l $(BUILD)/nextpnr.log \
	  --json $< --write $@ --device $(DEVICE) --freq $(CLK_MHZ) \
	  --vopt family=$(FAMILY) --vopt cst=$(CONSTR) $(NEXTPNR_FLAGS)

$(BITSTREAM): $(PNR_JSON)
	$(RUN) gowin_pack -d $(FAMILY) -o $@ $<
