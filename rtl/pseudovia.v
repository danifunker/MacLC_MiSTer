module pseudovia(
	input clk32,
	input reset,
	input cs,
	input rw, // 1=Read, 0=Write
	input [3:0] rs, // Register Select
	input [7:0] din,
	output reg [7:0] dout,
	output irq,

	// Interrupt Sources
	input vblank
);

	// Registers
	// Based on common Mac hardware reverse engineering (RBV/V8)
	// Offset 0x0: IER (Interrupt Enable)
	// Offset 0x1: IFR (Interrupt Flag)

	reg [7:0] ier;
	reg [7:0] ifr;

	// Bit assignments (typical for RBV/Pseudo-VIA):
	// Bit 0: VIA1 (Level 1) - usually aggregated here?
	// Bit 1: Slot 0 / Video
	// Bit 2: Slot 1
	// Bit 3: Slot 2
	// Bit 4: SCSI
	// Bit 5: ASC
	// Bit 6: VBL
	// Bit 7: SCC

	// For LC, VBL is critical.
	// VBL is often Bit 6 or Bit 1 (Slot 0).
	// Let's assume Bit 6 for VBL based on some RBV docs, or Bit 1.
	// MAME v8.cpp maps VBlank to Slot IRQ?
	// "m_screen->screen_vblank().set(m_pseudovia, FUNC(pseudovia_device::slot_irq_w<0x40>));"
	// 0x40 = Bit 6. So VBL is Bit 6.

	// Interrupt Logic
	wire [7:0] active_irqs;
	assign active_irqs[6] = vblank; // Level triggered
	assign active_irqs[5:0] = 0;
	assign active_irqs[7] = 0;

	assign irq = |(ifr & ier);

	// Edge detection for VBL to latch flag?
	// MAME uses level input? "slot_irq_w<0x40>".
	// "m_via_interrupt = m_via2_interrupt = m_scc_interrupt = 0;"
	// It seems to be level.

	always @(posedge clk32 or posedge reset) begin
		if (reset) begin
			ier <= 0;
			ifr <= 0;
		end else begin
			// Update IFR based on inputs
			// Assuming inputs are level and latching happens if edge?
			// Or pass-through?
			// Usually IFR bits are set by source and cleared by writing 1.

			if (vblank) ifr[6] <= 1;

			// CPU Access
			if (cs) begin
				if (!rw) begin // Write
					case (rs)
						4'h0: begin // IER
							// VIA style: Bit 7 determines Set/Clear?
							// Or RBV style: Direct write?
							// RBV/V8 usually direct write.
							ier <= din;
						end
						4'h1: begin // IFR (Clear)
							// Write 1 to clear
							ifr <= ifr & ~din;
						end
					endcase
				end
			end
		end
	end

	always @(*) begin
		dout = 0;
		if (cs && rw) begin
			case (rs)
				4'h0: dout = ier;
				4'h1: dout = ifr;
				4'h2: dout = {7'b0, vblank}; // Monitor ID or Slot ID? V8 puts Monitor ID here.
				// Offset 0x2/0x10?
				// V8: "via2_video_config_r" -> Offset 0x12?
				// Map in v8.cpp: 0x526000 range.
				// pseudovia_device::read map?
				// Let's implement basic IER/IFR at 0/1.
			endcase
		end
	end

endmodule
