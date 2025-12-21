module videoShifterLC(
	input clk, // Video Clock (25.175 MHz)
	input clk_sys, // System Clock (65 MHz)
	input [15:0] dataIn, // From Memory
	input loadPixels, // Unused/Legacy
	output [23:0] pixelOutRGB,

	// CLUT Write Interface
	input clutWrite,
	input [7:0] clutAddr,
	input [23:0] clutData,

	input videoBusControl, // Indicates valid data on bus (needs latching)
	input memoryLatch // Latch strobe
);

	// Palette Memory: 256 entries x 24 bits
	// Dual-port RAM inferred usually?
	// Port A: CPU Write (clk_sys)
	// Port B: Video Read (clk)
	reg [23:0] palette [255:0];

	// Write port
	always @(posedge clk_sys) begin
		if (clutWrite) begin
			palette[clutAddr] <= clutData;
		end
	end

	// Line Buffer (Dual Port RAM)
	// 1024 words x 16 bits.
	// Write (Sys), Read (Vid).

	reg [15:0] line_buffer [1023:0];
	reg [9:0] wr_ptr = 0;
	reg [9:0] rd_ptr = 0;

	// Write Logic (Sys Domain)
	// Reset wr_ptr on some signal?
	// We don't have a frame sync in Sys domain easily available from videoTimerLC other than vsync_start logic there.
	// But simply treating it as a circular buffer is safest if bandwidth is sufficient.
	// The read pointer chases the write pointer.
	// Write Logic:
	always @(posedge clk_sys) begin
		if (videoBusControl && memoryLatch) begin
			line_buffer[wr_ptr] <= dataIn;
			wr_ptr <= wr_ptr + 1'b1;
		end
	end

	// Read Logic (Vid Domain)
	reg pixel_sel = 0; // 0=High Byte, 1=Low Byte

	reg [15:0] current_word;

	// We assume initial sync is close enough or it self-corrects?
	// If write is faster, wr_ptr laps rd_ptr.
	// With 1024 depth, and 320 words per line used.
	// It's effectively a large FIFO.

	always @(posedge clk) begin
		// Pre-fetch word
		current_word <= line_buffer[rd_ptr];

		if (pixel_sel == 1) begin
			pixel_sel <= 0;
			rd_ptr <= rd_ptr + 1'b1;
		end else begin
			pixel_sel <= 1;
		end
	end

	wire [7:0] pixel = (pixel_sel == 0) ? current_word[15:8] : current_word[7:0];

	// Palette Lookup (Read Port)
	reg [23:0] rgb_out;
	always @(posedge clk) begin
		rgb_out <= palette[pixel];
	end

	assign pixelOutRGB = rgb_out;

	// Initial Palette
	integer i;
	initial begin
		for (i=0; i<256; i=i+1)
			palette[i] = {i[7:0], i[7:0], i[7:0]};
	end

endmodule
