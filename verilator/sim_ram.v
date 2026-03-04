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

// 16MB of RAM (8M words of 16 bits)
// Address bits [22:0] used, giving 8MW = 16MB
// SDRAM layout: motherboard $000000, SIMM $100000, ROM $500000, VRAM $580000, floppies $600000+
reg [15:0] mem [0:8388607];  // 8M words = 16MB

// Simple synchronous read/write
// Debug: track writes for verification
reg [22:0] last_wr_addr;
reg [15:0] last_wr_data;
reg        last_wr_valid;
integer    wr_count = 0;
integer    vram_rd_count = 0;

integer vram_wr_count = 0;
integer rd_count = 0;
integer rom_rd_count = 0;

always @(posedge clk) begin
	// Writes are allowed even during reset (needed for ROM loading)
	if (we && |ds) begin
		// Write with byte strobes
		if (ds[1]) mem[addr[22:0]][15:8] <= din[15:8];
		if (ds[0]) mem[addr[22:0]][7:0]  <= din[7:0];
		last_wr_addr <= addr[22:0];
		last_wr_data <= din;
		last_wr_valid <= 1;
		wr_count <= wr_count + 1;
		// Debug first 100 writes, then every 10000th
		if (wr_count < 100 || wr_count % 10000 == 0)
			$display("sim_ram WR[%0d] @%0t: addr=%h din=%h ds=%b",
				wr_count, $time, addr[22:0], din, ds);
		// Debug VRAM writes (VRAM is at 0x1A0000-0x1DFFFF word address = 0x340000-0x3BFFFF byte)
		if (addr[22:0] >= 23'h580000 && addr[22:0] < 23'h5C0000) begin
			if (vram_wr_count < 20 || vram_wr_count % 1000 == 0)
				$display("sim_ram VRAM_WR[%0d]: addr=%h (line %0d) din=%h ds=%b",
					vram_wr_count, addr[22:0], (addr[22:0] - 23'h580000) >> 9, din, ds);
			vram_wr_count <= vram_wr_count + 1;
		end
		// Debug all writes in non-ROM area to see where CPU is writing
		if (wr_count >= 20 && wr_count < 50 && addr[21] == 0)
			$display("sim_ram WR[%0d]: addr=%h din=%h ds=%b (after ROM)",
				wr_count, addr[22:0], din, ds);
	end

	if (reset) begin
		last_wr_valid <= 0;
		rd_count <= 0;
		rom_rd_count <= 0;
		// Don't reset wr_count so we can track all writes
	end else begin
		if (oe) begin
			dout <= mem[addr[22:0]];
							// ROM is at word address $500000-$53FFFF
							if (addr[22:0] >= 23'h500000 && addr[22:0] < 23'h540000 && rom_rd_count < 10000) begin
								$display("sim_ram RD_ROM[%0d] @%0t: addr=%h dout=%h",
									rom_rd_count, $time, addr[22:0], mem[addr[22:0]]);
								rom_rd_count <= rom_rd_count + 1;
							end			rd_count <= rd_count + 1;
			// Debug video reads (VRAM is at 0x1A0000 = 0x340000 >> 1 in word address)
			if (addr[22:0] >= 23'h580000 && addr[22:0] < 23'h5C0000) begin
				if (vram_rd_count < 50)
					$display("sim_ram VRAM_RD[%0d]: addr=%h (line %0d) dout=%h",
						vram_rd_count, addr[22:0], (addr[22:0] - 23'h580000) >> 9, mem[addr[22:0]]);
				vram_rd_count <= vram_rd_count + 1;
			end
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
