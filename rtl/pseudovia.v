module pseudovia(
	input clk,
	input reset,
	input _cs,
	input _rw, // 1=Read, 0=Write
	input [3:0] addr, // A12-A9 or similar?
	input [7:0] data_in,
	output reg [7:0] data_out,
	output _irq,

	input vbl_in
);

	// Registers
	// We need to support VBL interrupt.
	// Pseudo-VIA / RBV registers:
	// IER (Interrupt Enable)
	// IFR (Interrupt Flag)
	// Base address usually handles offsets.

	// Assuming simple model:
	// Addr 0: IER
	// Addr 1: IFR

	reg [7:0] ier;
	reg [7:0] ifr;

	// VBL Edge Detection
	reg vbl_prev;
	always @(posedge clk) begin
		vbl_prev <= vbl_in;
		if (reset) begin
			ier <= 0;
			ifr <= 0;
		end else begin
			// VBL Rising Edge sets bit 0 of IFR
			if (vbl_in && !vbl_prev) begin
				ifr[0] <= 1'b1;
			end

			// CPU Access
			if (_cs) begin
				if (!_rw) begin // Write
					case (addr[0])
						0: ier <= data_in; // Write IER
						1: ifr <= ifr & ~data_in; // Write 1 to Clear IFR
					endcase
				end else begin // Read
					case (addr[0])
						0: data_out <= ier;
						1: data_out <= ifr;
						default: data_out <= 8'h00;
					endcase
				end
			end
		end
	end

	// IRQ Generation
	// Active Low
	assign _irq = ~((ifr & ier) != 0);

endmodule
