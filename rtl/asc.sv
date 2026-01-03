// Apple Sound Chip (ASC) Stub for Mac LC
// Returns correct version and status to satisfy ROM boot checks

module asc(
	input         clk,
	input         reset,
	
	// CPU Interface
	input         cs,      // Chip Select (selectASC)
	input  [11:0] addr,    // Offset within $800-$FFF registers (A11-A0)
	input   [7:0] data_in,
	output  [7:0] data_out,
	input         we,      // Write Enable
	
	// Interrupts
	output reg    irq      // Active HIGH (PseudoVIA inverts it)
);

	// Registers
	// 0x800: VERSION
	// 0x801: MODE
	// 0x802: CONTROL
	// 0x804: FIFO STAT
	
	// We implement a small register file for the control registers
	reg [7:0] regs [0:15]; // 0x800 - 0x80F
	
	// FIFO Status: Bits 1 (A Empty) and 3 (B Empty) set by default
	reg [7:0] fifo_stat;
	
	always @(posedge clk) begin
		if (reset) begin
			irq <= 0;
			fifo_stat <= 8'h0A; // FIFOs Empty
			regs[0] <= 8'hE8;   // Version (Read-Only)
			regs[1] <= 0;       // Mode
			regs[2] <= 0;       // Control
		end else if (cs) begin
			if (we) begin
				// Write
				if (addr >= 12'h800 && addr <= 12'h80F) begin
					case (addr[3:0])
						4'h0: ; // Version RO
						4'h1: begin
							regs[1] <= data_in; // Mode
							// If Mode=1 (FIFO), maybe trigger IRQ if empty?
							if (data_in == 1) irq <= 1; // Assert IRQ immediately (Empty)
							else irq <= 0;
						end
						4'h4: begin
							// Writing to FIFOSTAT might clear bits?
							// MAME says reading clears.
						end
						default: regs[addr[3:0]] <= data_in;
					endcase
				end
			end else begin
				// Read - handled in comb/reg logic, but IRQ clearing is synchronous
				if (addr == 12'h804) begin
					// Reading FIFOSTAT clears interrupts
					irq <= 0;
				end
			end
		end
	end
	
	reg [7:0] data_out_reg;
	always @(*) begin
		if (addr >= 12'h800 && addr <= 12'h80F) begin
			case (addr[3:0])
				4'h0: data_out_reg = 8'hE8; // Version
				4'h4: data_out_reg = fifo_stat; // FIFO Status
				default: data_out_reg = regs[addr[3:0]];
			endcase
		end else begin
			data_out_reg = 8'h00; // FIFOs return 0
		end
	end
	
	assign data_out = data_out_reg;

endmodule
