# Makefile for Mac LC VIA/Egret Boot Sequence Testbench
#
# Supports Verilator, Icarus Verilog, and Vivado simulation

# Testbench source
TB_SRC = maclc_via_egret_boot_tb.sv

# DUT sources (adjust these to point to your actual VIA implementation)
DUT_SRC = # Add your VIA module files here
# Example: DUT_SRC = ../rtl/via_6522.sv ../rtl/via_timer.sv

# Simulation target
SIM ?= verilator

# Verilator options
VERILATOR = verilator
VERILATOR_FLAGS = --trace --trace-structs -Wall -Wno-fatal --cc
VERILATOR_TOP = maclc_via_egret_boot_tb

# Icarus Verilog options
IVERILOG = iverilog
IVERILOG_FLAGS = -g2012 -Wall
VVP = vvp

# Output files
VCD_FILE = maclc_boot_sequence.vcd
WAVE_VIEWER = gtkwave

.PHONY: all clean sim wave help

all: sim

# Verilator simulation
verilator: $(TB_SRC) $(DUT_SRC)
	@echo "=== Building with Verilator ==="
	$(VERILATOR) $(VERILATOR_FLAGS) $(TB_SRC) $(DUT_SRC) --exe --build
	@echo "=== Running Verilator simulation ==="
	./obj_dir/V$(VERILATOR_TOP)

# Icarus Verilog simulation
iverilog: $(TB_SRC) $(DUT_SRC)
	@echo "=== Compiling with Icarus Verilog ==="
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim.vvp $(TB_SRC) $(DUT_SRC)
	@echo "=== Running simulation ==="
	$(VVP) sim.vvp

# Run simulation (default to Verilator)
sim:
ifeq ($(SIM),verilator)
	$(MAKE) verilator
else ifeq ($(SIM),iverilog)
	$(MAKE) iverilog
else
	@echo "Unknown simulator: $(SIM)"
	@echo "Use 'make sim SIM=verilator' or 'make sim SIM=iverilog'"
	@exit 1
endif

# View waveforms
wave: $(VCD_FILE)
	@echo "=== Opening waveform viewer ==="
	$(WAVE_VIEWER) $(VCD_FILE) &

# Generate signal sequence from MAME logs
generate: handshake.log
	@echo "=== Generating testbench stimulus from MAME logs ==="
	python3 generate_testbench.py handshake.log > generated_stimulus.sv
	@echo "Generated stimulus saved to generated_stimulus.sv"

# Analyze MAME logs
analyze: handshake.log
	@echo "=== Analyzing MAME boot sequence ==="
	python3 generate_testbench.py handshake.log

# Clean build artifacts
clean:
	rm -rf obj_dir/
	rm -f sim.vvp
	rm -f $(VCD_FILE)
	rm -f generated_stimulus.sv
	rm -f *.log

# Help
help:
	@echo "Mac LC VIA/Egret Boot Sequence Testbench"
	@echo ""
	@echo "Targets:"
	@echo "  make sim SIM=verilator  - Run simulation with Verilator (default)"
	@echo "  make sim SIM=iverilog   - Run simulation with Icarus Verilog"
	@echo "  make wave               - Open waveform viewer (GTKWave)"
	@echo "  make generate           - Generate stimulus from MAME logs"
	@echo "  make analyze            - Analyze MAME log patterns"
	@echo "  make clean              - Remove build artifacts"
	@echo ""
	@echo "Requirements:"
	@echo "  - Verilator or Icarus Verilog"
	@echo "  - GTKWave (for waveform viewing)"
	@echo "  - Python 3 (for log analysis)"
	@echo ""
	@echo "Usage:"
	@echo "  1. Edit TB_SRC to point to your VIA module"
	@echo "  2. Run: make sim"
	@echo "  3. View: make wave"
