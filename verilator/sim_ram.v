//
// sim_ram.v
//
// Simple RAM module for Verilator simulation of MacLC
// Replaces the SDRAM controller with synchronous RAM
//

module sim_ram
(
	// cpu/chipset interface - same as sdram.v
	input               clk,        // system clock
	input               reset,      // reset signal

	input [15:0]        din,        // data input from chipset/cpu
	output reg [15:0]   dout,       // data output to chipset/cpu
	input [24:0]        addr,       // 25 bit word address
	input [1:0]         ds,         // upper/lower data strobe
	input               oe,         // cpu/chipset requests read
	input               we          // cpu/chipset requests write
);

// 8MB of RAM (4M words of 16 bits)
// Address bits [21:0] used, giving 4MW = 8MB
// Upper address bits select ROM vs RAM area
reg [15:0] mem [0:4194303];  // 4M words = 8MB

// Simple synchronous read/write
// Debug: track writes for verification
reg [21:0] last_wr_addr;
reg [15:0] last_wr_data;
reg        last_wr_valid;
integer    wr_count = 0;

always @(posedge clk) begin
	// Writes are allowed even during reset (needed for ROM loading)
	if (we && |ds) begin
		// Write with byte strobes
		if (ds[1]) mem[addr[21:0]][15:8] <= din[15:8];
		if (ds[0]) mem[addr[21:0]][7:0]  <= din[7:0];
		last_wr_addr <= addr[21:0];
		last_wr_data <= din;
		last_wr_valid <= 1;
		wr_count <= wr_count + 1;
		// Debug first 20 writes
		if (wr_count < 20)
			$display("sim_ram WR[%0d]: addr=%h din=%h ds=%b",
				wr_count, addr[21:0], din, ds);
	end

	if (reset) begin
		last_wr_valid <= 0;
		// Don't reset wr_count so we can track all writes
	end else begin
		if (oe) begin
			dout <= mem[addr[21:0]];
		end
	end
end

// Allow ROM/RAM initialization from simulation
// verilator tracing_off
/* verilator lint_off UNUSED */
initial begin
	// Memory will be initialized by the simulation testbench
	// via ioctl_download mechanism
end
/* verilator lint_on UNUSED */
// verilator tracing_on

endmodule
