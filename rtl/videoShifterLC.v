module videoShifterLC(
	input clk, // Video Clock (25.175 MHz)
	input clk_sys, // System Clock (65 MHz)
	input [15:0] dataIn, // From Memory
	input loadPixels, // Active high when dataIn is valid pixel data
	output [23:0] pixelOutRGB,

	// CLUT Write Interface
	input clutWrite,
	input [7:0] clutAddr,
	input [23:0] clutData, // Can be used for simplified write
	input [1:0] clutByteSel, // 0=Red, 1=Green, 2=Blue
	input [7:0] clutByteData, // Data for byte write

	input videoBusControl, // Indicates valid data on bus (needs latching)
	input memoryLatch, // Latch strobe

	// Synchronization
	input vsync // From videoTimerLC (Vid Domain) - used to reset pointers
);

	// Palette Memory: 256 entries x 24 bits
	reg [23:0] palette [255:0];

	// Write port with Byte Selection for Color
	always @(posedge clk_sys) begin
		if (clutWrite) begin
			if (clutByteSel == 0) palette[clutAddr][23:16] <= clutByteData; // Red
			if (clutByteSel == 1) palette[clutAddr][15:8] <= clutByteData;  // Green
			if (clutByteSel == 2) palette[clutAddr][7:0] <= clutByteData;   // Blue

			// Fallback/Legacy full write if needed (optional)
			// palette[clutAddr] <= clutData;
		end
	end

	// Line Buffer (Dual Port RAM)
	reg [15:0] line_buffer [1023:0];
	reg [9:0] wr_ptr = 0;
	reg [9:0] rd_ptr = 0;

	// Reset pointers on VSync (Sys Domain)
	reg vsync_sys_1, vsync_sys_2;
	always @(posedge clk_sys) begin
		vsync_sys_1 <= vsync;
		vsync_sys_2 <= vsync_sys_1;
	end

	wire vsync_sys_edge = !vsync_sys_1 && vsync_sys_2;

	// Write Logic (Sys Domain)
	// Only write if loadPixels is true (Active Line)
	always @(posedge clk_sys) begin
		if (vsync_sys_edge) begin
			wr_ptr <= 0;
		end else if (videoBusControl && memoryLatch && loadPixels) begin
			line_buffer[wr_ptr] <= dataIn;
			wr_ptr <= wr_ptr + 1'b1;
		end
	end

	// Read Logic (Vid Domain)
	reg pixel_sel = 0; // 0=High Byte, 1=Low Byte
	reg [15:0] current_word;

	// Detect VSync edge in Vid Domain
	reg vsync_vid_1;
	always @(posedge clk) vsync_vid_1 <= vsync;
	wire vsync_vid_edge = !vsync && vsync_vid_1;

	always @(posedge clk) begin
		if (vsync_vid_edge) begin
			rd_ptr <= 0;
			pixel_sel <= 0;
		end else begin
			// Pre-fetch word
			current_word <= line_buffer[rd_ptr];

			if (pixel_sel == 1) begin
				pixel_sel <= 0;
				rd_ptr <= rd_ptr + 1'b1;
			end else begin
				pixel_sel <= 1;
			end
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
