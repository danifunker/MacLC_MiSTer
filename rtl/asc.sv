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
	
	// FIFO Simulation
	reg [10:0] fifo_count; // Combined count for simplicity
	reg [15:0] tick_div;   // Timer for draining FIFO
	reg [7:0]  fifo_stat;
	
	always @(posedge clk) begin
		// Drain FIFO periodically (simulates playback)
		tick_div <= tick_div + 1'b1;
		
		if (reset) begin
			irq <= 0;
			fifo_count <= 0;
			fifo_stat <= 8'h00; // Fake: Not Empty to satisfy ROM?
			regs[0] <= 8'hE8;   // Version (Read-Only)
			regs[1] <= 0;       // Mode
			regs[2] <= 0;       // Control
		end else begin
			// FIFO Status Logic
			// Force 0 for now to prevent "Empty" deadlock if ROM waits for data it didn't write
			fifo_stat <= 8'h00; 
			// fifo_stat[1] <= (fifo_count == 0); // A Empty
			// fifo_stat[3] <= (fifo_count == 0); // B Empty
			// fifo_stat[0] <= (fifo_count >= 256); // A Half
			// fifo_stat[2] <= (fifo_count >= 256); // B Half

			if (cs) begin
				if (we) begin
					// FIFO Write
					if (addr < 12'h800) begin
						if (fifo_count < 1024) fifo_count <= fifo_count + 1'b1;
					end
					// Register Write
					else if (addr >= 12'h800 && addr <= 12'h80F) begin
						case (addr[3:0])
							4'h0: ; // Version RO
							4'h1: begin
								regs[1] <= data_in; // Mode
								// If Mode=1 (FIFO), check IRQ
								if (data_in == 1 && fifo_count == 0) irq <= 1; 
								else irq <= 0;
							end
							4'h4: ; // FIFOSTAT RO/Clear
							default: regs[addr[3:0]] <= data_in;
						endcase
					end
				end else begin
					// Read
					if (addr == 12'h804) begin
						irq <= 0; // Clear IRQ
					end
				end
			end else begin
				// Decrement if no write happening
				if (tick_div == 0 && fifo_count > 0)
					fifo_count <= fifo_count - 1'b1;
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
