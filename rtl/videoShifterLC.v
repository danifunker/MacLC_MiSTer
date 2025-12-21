module videoShifterLC(
	input clk32,
	input loadPixels,
	input [15:0] dataIn,
	output [23:0] pixelOut,

	// CLUT Interface
	input [1:0] clut_addr, // 0=Addr, 1=Data (assuming mapped to A1, A2)
	input clut_wr,
	input [7:0] clut_data
);

	reg [15:0] shiftRegister;
	reg [7:0]  currentPixel;

	// Palette RAM (256 x 24-bit)
	reg [7:0] palette_r [0:255];
	reg [7:0] palette_g [0:255];
	reg [7:0] palette_b [0:255];

	// Palette Write State
	reg [7:0] clut_ptr;
	reg [1:0] clut_step; // 0=R, 1=G, 2=B

	initial begin
		// Initialize with grayscale ramp for safety
		integer i;
		for (i = 0; i < 256; i = i + 1) begin
			palette_r[i] = i;
			palette_g[i] = i;
			palette_b[i] = i;
		end
	end

	// CPU Write Logic
	always @(posedge clk32) begin
		if (clut_wr) begin
			if (clut_addr == 0) begin // Address Register
				clut_ptr <= clut_data;
				clut_step <= 0;
			end else if (clut_addr == 1) begin // Data Register
				case (clut_step)
					0: begin
						palette_r[clut_ptr] <= clut_data;
						clut_step <= 1;
					end
					1: begin
						palette_g[clut_ptr] <= clut_data;
						clut_step <= 2;
					end
					2: begin
						palette_b[clut_ptr] <= clut_data;
						clut_step <= 0;
						clut_ptr <= clut_ptr + 1;
					end
				endcase
			end
		end
	end

	// Pixel Shifter Logic
	always @(posedge clk32) begin
		if (loadPixels) begin
			shiftRegister <= dataIn;
			currentPixel <= dataIn[15:8]; // First pixel (big endian)
		end else begin
			shiftRegister <= {shiftRegister[7:0], 8'h00};
			currentPixel <= shiftRegister[7:0]; // Next pixel
		end
	end

	// Palette Lookup
	assign pixelOut = {palette_r[currentPixel], palette_g[currentPixel], palette_b[currentPixel]};

endmodule
