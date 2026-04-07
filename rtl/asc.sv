// Apple Sound Chip (ASC) for Mac LC
//
// Real ASC has two 1 KB FIFOs (channel A at $F14000-$F143FF and channel B
// at $F14400-$F147FF) and a register file at $F14800-$F1480F. The chip
// drives DFAC via SND[0:2] + DFAC_CLK on real hardware; in this core the
// FIFOs are popped at the sample rate and the resulting bytes are exposed
// directly as 16-bit samples on sample_l/sample_r — no DFAC modelling.
//
// Per docs/plan_040526.md Commit B (Step 3a): the FIFO + sample-output
// path is gated behind `USE_ASC_AUDIO`. When undefined the original
// register stub remains so we can fall back instantly during debugging.
// Top-level sample wiring lands in Commit C.

module asc(
	input         clk,
	input         reset,

	// CPU Interface
	input         cs,      // Chip Select (selectASC)
	input  [11:0] addr,    // Offset within ASC window (4 KB)
	input   [7:0] data_in,
	output  [7:0] data_out,
	input         we,      // Write Enable

	// Sample output (Commit C will route to AUDIO_L/R)
	output reg signed [15:0] sample_l,
	output reg signed [15:0] sample_r,
	output reg               sample_tick,

	// Interrupts
	output reg    irq      // Active HIGH (PseudoVIA inverts it)
);

`ifdef USE_ASC_AUDIO

	// ============================================================
	// Real FIFO implementation
	// ============================================================
	// Sample rate divider: ~22.05 kHz from 32.5 MHz clk_sys → ÷1474.
	localparam SAMPLE_DIV = 16'd1474;

	reg [7:0]  fifo_a [0:1023];
	reg [7:0]  fifo_b [0:1023];
	reg [9:0]  wptr_a, rptr_a;
	reg [9:0]  wptr_b, rptr_b;
	reg [10:0] count_a, count_b;
	reg [15:0] sample_div;

	reg [7:0] regs [0:15];
	reg [7:0] fifo_stat;

	wire fifo_a_write = cs && we && (addr < 12'h400);
	wire fifo_b_write = cs && we && (addr >= 12'h400) && (addr < 12'h800);
	wire reg_write   = cs && we && (addr >= 12'h800) && (addr <= 12'h80F);
	wire reg_read    = cs && !we && (addr >= 12'h800) && (addr <= 12'h80F);

	wire pop_tick    = (sample_div == SAMPLE_DIV - 1);
	wire pop_a       = pop_tick && (count_a != 0);
	wire pop_b       = pop_tick && (count_b != 0);

	integer i;
	always @(posedge clk) begin
		sample_tick <= 1'b0;

		if (reset) begin
			wptr_a <= 0; rptr_a <= 0; count_a <= 0;
			wptr_b <= 0; rptr_b <= 0; count_b <= 0;
			sample_div <= 0;
			sample_l <= 0;
			sample_r <= 0;
			irq <= 0;
			fifo_stat <= 8'h05;
			for (i = 0; i < 16; i = i + 1) regs[i] <= 8'h00;
			regs[0] <= 8'hE8; // Version (RO)
		end else begin
			// Sample-rate divider
			if (sample_div == SAMPLE_DIV - 1) begin
				sample_div <= 0;
				sample_tick <= 1'b1;
				// Pop one byte per channel (unsigned 8 → signed 16)
				if (count_a != 0) begin
					sample_l <= {~fifo_a[rptr_a][7], fifo_a[rptr_a][6:0], 8'h00};
					rptr_a   <= rptr_a + 1'b1;
				end
				if (count_b != 0) begin
					sample_r <= {~fifo_b[rptr_b][7], fifo_b[rptr_b][6:0], 8'h00};
					rptr_b   <= rptr_b + 1'b1;
				end
			end else begin
				sample_div <= sample_div + 1'b1;
			end

			// FIFO A counter (handles concurrent push + pop)
			case ({fifo_a_write, pop_a})
				2'b10: if (count_a < 1024) count_a <= count_a + 1'b1;
				2'b01: count_a <= count_a - 1'b1;
				default: ; // 00 or 11 → no net change
			endcase
			if (fifo_a_write && count_a < 1024) begin
				fifo_a[wptr_a] <= data_in;
				wptr_a <= wptr_a + 1'b1;
			end

			// FIFO B counter
			case ({fifo_b_write, pop_b})
				2'b10: if (count_b < 1024) count_b <= count_b + 1'b1;
				2'b01: count_b <= count_b - 1'b1;
				default: ;
			endcase
			if (fifo_b_write && count_b < 1024) begin
				fifo_b[wptr_b] <= data_in;
				wptr_b <= wptr_b + 1'b1;
			end

			// Register write
			if (reg_write) begin
				case (addr[3:0])
					4'h0: ; // Version RO
					4'h4: ; // FIFO STAT RO
					default: regs[addr[3:0]] <= data_in;
				endcase
			end

			// FIFO status (live fill levels)
			fifo_stat[0] <= (count_a < 1024);
			fifo_stat[1] <= (count_a == 1024);
			fifo_stat[2] <= (count_b < 1024);
			fifo_stat[3] <= (count_b == 1024);
			fifo_stat[7:4] <= 4'h0;

			// IRQ: assert when either FIFO drops below half full
			if (reg_read && addr == 12'h804)
				irq <= 1'b0;
			else
				irq <= (count_a < 512) || (count_b < 512);
		end
	end

	reg [7:0] data_out_reg;
	always @(*) begin
		data_out_reg = 8'h00;
		if (addr >= 12'h800 && addr <= 12'h80F) begin
			case (addr[3:0])
				4'h0:    data_out_reg = 8'hE8;
				4'h4:    data_out_reg = fifo_stat;
				default: data_out_reg = regs[addr[3:0]];
			endcase
		end
	end
	assign data_out = data_out_reg;

`else

	// ============================================================
	// Original register stub (USE_ASC_AUDIO undefined)
	// ============================================================
	// Sample outputs are tied off; the legacy DMA path in
	// dataController_top is still driving AUDIO_L/R until Commit C.
	always @(*) begin
		sample_l    = 16'sd0;
		sample_r    = 16'sd0;
		sample_tick = 1'b0;
	end

	reg [7:0] regs [0:15];
	reg [10:0] fifo_count;
	reg [9:0]  tick_div;
	reg [7:0]  fifo_stat;

	always @(posedge clk) begin
		tick_div <= tick_div + 1'b1;

		if (reset) begin
			irq <= 0;
			fifo_count <= 0;
			fifo_stat <= 8'h05;
			regs[0] <= 8'hE8;
			regs[1] <= 0;
			regs[2] <= 0;
		end else begin
			fifo_stat[0] <= (fifo_count < 1024);
			fifo_stat[1] <= (fifo_count >= 1024);
			fifo_stat[2] <= (fifo_count < 1024);
			fifo_stat[3] <= (fifo_count >= 1024);

			if (cs) begin
				if (we) begin
					if (addr < 12'h800) begin
						if (fifo_count < 1024) fifo_count <= fifo_count + 1'b1;
					end
					else if (addr >= 12'h800 && addr <= 12'h80F) begin
						case (addr[3:0])
							4'h0: ;
							4'h1: begin
								regs[1] <= data_in;
								if (data_in == 1 && fifo_count == 0) irq <= 1;
								else irq <= 0;
							end
							4'h4: ;
							default: regs[addr[3:0]] <= data_in;
						endcase
					end
				end else begin
					if (addr == 12'h804) irq <= 0;
				end
			end
			else if (tick_div == 0 && fifo_count > 0) begin
				fifo_count <= fifo_count - 1'b1;
			end
		end
	end

	reg [7:0] data_out_reg;
	always @(*) begin
		if (addr >= 12'h800 && addr <= 12'h80F) begin
			case (addr[3:0])
				4'h0:    data_out_reg = 8'hE8;
				4'h4:    data_out_reg = fifo_stat;
				default: data_out_reg = regs[addr[3:0]];
			endcase
		end else begin
			data_out_reg = 8'h00;
		end
	end
	assign data_out = data_out_reg;

`endif

endmodule
