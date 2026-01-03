// Apple Sound Chip (ASC) for Mac LC (V8 variant)
// Based on MAME's asc.cpp by R. Belmont
//
// V8 variant behaviors (from MAME):
// - VERSION (0x800): Always returns 0xE8
// - MODE (0x801): Always returns 1 (FIFO mode forced)
// - CONTROL (0x802): Always returns 1
// - FIFOSTAT (0x804): Returns only bits 0-1, reading clears register and IRQ
// - FIFOMODE (0x803): Write 0x80 clears FIFOs
//
// FIFOSTAT bits:
//   Bit 0: FIFO A less than half full (half-empty)
//   Bit 1: FIFO A empty
//   Bit 2: FIFO B less than half full (half-empty)
//   Bit 3: FIFO B empty
// Note: V8 only returns bits 0-1 (FIFO A status only)

module asc(
	input         clk,
	input         reset,

	// CPU Interface
	input         cs,      // Chip Select (selectASC)
	input  [11:0] addr,    // Offset within ASC space (A11-A0)
	input   [7:0] data_in,
	output  [7:0] data_out,
	input         we,      // Write Enable

	// Interrupts
	output reg    irq      // Active HIGH (directly directly directly inverts it)
);

	// Register addresses (accent from 0x800)
	localparam R_VERSION  = 12'h800;
	localparam R_MODE     = 12'h801;
	localparam R_CONTROL  = 12'h802;
	localparam R_FIFOMODE = 12'h803;
	localparam R_FIFOSTAT = 12'h804;
	localparam R_WTCONTROL= 12'h805;
	localparam R_VOLUME   = 12'h806;
	localparam R_CLOCK    = 12'h807;

	// Internal state
	reg [7:0] fifo_stat;      // FIFO status register
	reg [7:0] mode_reg;       // Mode register (written value, but V8 always reads 1)
	reg [7:0] control_reg;    // Control register
	reg [7:0] fifo_mode_reg;  // FIFO mode register
	reg [7:0] volume_reg;     // Volume register

	// FIFO state (simplified - just track empty status for boot)
	// In a full implementation, these would be actual FIFOs
	reg fifo_a_empty;
	reg fifo_b_empty;

	// Read logic
	reg [7:0] data_out_reg;
	reg fifostat_read_pending;

	always @(posedge clk) begin
		if (reset) begin
			irq <= 0;
			// FIFOs start empty - set both half-empty and empty bits
			fifo_stat <= 8'h0F;  // Bits 0-3: both FIFOs empty and half-empty
			fifo_a_empty <= 1;
			fifo_b_empty <= 1;
			mode_reg <= 0;
			control_reg <= 0;
			fifo_mode_reg <= 0;
			volume_reg <= 0;
			fifostat_read_pending <= 0;
		end else begin
			// Clear FIFOSTAT after it was read (MAME behavior)
			if (fifostat_read_pending) begin
				fifo_stat <= 8'h00;
				irq <= 0;
				fifostat_read_pending <= 0;
			end

			if (cs) begin
				if (we) begin
					// Write operations
					case (addr)
						R_MODE: begin
							mode_reg <= data_in & 8'h03;  // Only bits 0-1 writable
							// Mode change resets FIFOs
							if ((data_in & 8'h03) != (mode_reg & 8'h03)) begin
								fifo_stat <= 8'h0F;  // FIFOs become empty
								fifo_a_empty <= 1;
								fifo_b_empty <= 1;
							end
						end

						R_CONTROL: begin
							control_reg <= data_in;
						end

						R_FIFOMODE: begin
							fifo_mode_reg <= data_in;
							// Bit 7: Clear FIFOs
							if (data_in[7]) begin
								fifo_stat <= 8'h0A;  // MAME sets 0x0A on FIFO clear (empty bits only)
								fifo_a_empty <= 1;
								fifo_b_empty <= 1;
							end
						end

						R_VOLUME: begin
							volume_reg <= data_in;
						end

						default: ;  // Other registers ignored for now
					endcase
				end else begin
					// Read operations - mark FIFOSTAT read for clearing next cycle
					if (addr == R_FIFOSTAT) begin
						fifostat_read_pending <= 1;
					end
				end
			end

			// Continuous FIFO status updates (V8 behavior from MAME)
			// When FIFOs are empty, keep the status bits set
			if (fifo_a_empty && !fifostat_read_pending) begin
				fifo_stat[0] <= 1;  // FIFO A half-empty
				fifo_stat[1] <= 1;  // FIFO A empty
			end
			if (fifo_b_empty && !fifostat_read_pending) begin
				fifo_stat[2] <= 1;  // FIFO B half-empty
				fifo_stat[3] <= 1;  // FIFO B empty
			end
		end
	end

	// Combinational read output
	always @(*) begin
		case (addr)
			R_VERSION:  data_out_reg = 8'hE8;           // V8 version
			R_MODE:     data_out_reg = 8'h01;           // V8 always returns 1
			R_CONTROL:  data_out_reg = 8'h01;           // V8 always returns 1
			R_FIFOMODE: data_out_reg = fifo_mode_reg;
			R_FIFOSTAT: data_out_reg = fifo_stat & 8'h03;  // V8: only bits 0-1
			R_VOLUME:   data_out_reg = volume_reg;
			default: begin
				// FIFO A: 0x000-0x3FF
				// FIFO B: 0x400-0x7FF
				// Other registers: 0x800-0xFFF
				if (addr < 12'h400)
					data_out_reg = 8'h00;  // FIFO A reads as 0 (empty)
				else if (addr < 12'h800)
					data_out_reg = 8'h00;  // FIFO B reads as 0 (empty)
				else
					data_out_reg = 8'h00;  // Unknown register
			end
		endcase
	end

	assign data_out = data_out_reg;

endmodule
