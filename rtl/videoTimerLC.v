module videoTimerLC(
	input clk, // 25.175 MHz (Pixel Clock)
	input clk_sys, // System Clock (65 MHz for LC)
	input [1:0] busCycle,
	input videoBusControl, // From addrController, indicates a video fetch slot
	output [21:0] videoAddr,
	output reg hsync,
	output reg vsync,
	output _hblank,
	output _vblank,
	output loadPixels // Used to signal Shifter
);

	// VGA 640x480 @ 60Hz Timing (25.175 MHz pixel clock)
	localparam H_ACTIVE = 640;
	localparam H_FP = 16;
	localparam H_SYNC = 96;
	localparam H_BP = 48;
	localparam H_TOTAL = 800;

	localparam V_ACTIVE = 480;
	localparam V_FP = 10;
	localparam V_SYNC = 2;
	localparam V_BP = 33;
	localparam V_TOTAL = 525;

	reg [9:0] h_count;
	reg [9:0] v_count;

	always @(posedge clk) begin
		if (h_count == H_TOTAL - 1) begin
			h_count <= 0;
			if (v_count == V_TOTAL - 1)
				v_count <= 0;
			else
				v_count <= v_count + 1'b1;
		end else begin
			h_count <= h_count + 1'b1;
		end
	end

	wire h_sync_active = (h_count >= (H_ACTIVE + H_FP)) && (h_count < (H_ACTIVE + H_FP + H_SYNC));
	wire v_sync_active = (v_count >= (V_ACTIVE + V_FP)) && (v_count < (V_ACTIVE + V_FP + V_SYNC));

	always @(posedge clk) begin
		hsync <= ~h_sync_active;
		vsync <= ~v_sync_active;
	end

	assign _hblank = (h_count < H_ACTIVE);
	assign _vblank = (v_count < V_ACTIVE);

	// Address Generation (System Clock Domain)
	// We duplicate the counters in the system domain to track active video lines.
	// This allows us to pause fetching during blanking, preventing FIFO overflow.
	// Since clk_sys (65MHz) > clk (25MHz), we use a fractional counter or just run faster and stall.
	// Actually, we are driven by `videoBusControl` which happens at 16.25 MHz (65/4).
	// We need to count 320 fetches (640 pixels) per line.

	// Cross VSync to System Domain to reset counters
	reg vsync_sys_1, vsync_sys_2;
	always @(posedge clk_sys) begin
		vsync_sys_1 <= v_sync_active;
		vsync_sys_2 <= vsync_sys_1;
	end
	wire vsync_start = vsync_sys_1 && !vsync_sys_2;

	reg [21:0] addr;
	reg [8:0] word_count; // 0..319
	reg [9:0] line_count; // 0..524

	// State machine for line fetching?
	// Simply: If `videoBusControl` and `word_count < 320` and `line_count < 480`: Fetch.
	// We need to detect "End of Line" in Sys domain.
	// We don't have HSync from Vid domain easily aligned.
	// We can estimate timing?
	// 1 line = 31.77 us.
	// 65 MHz clocks = 2065 clocks.
	// We can build a line timer in Sys domain.

	reg [11:0] sys_h_count;

	// 25.175 MHz * 800 clocks = 31.777 us.
	// 65 MHz * X = 31.777 us -> X = 2065.5.
	// Let's use 2065.
	localparam SYS_H_TOTAL = 2065;
	localparam SYS_V_ACTIVE = 480;

	always @(posedge clk_sys) begin
		if (vsync_start) begin
			addr <= 0;
			word_count <= 0;
			line_count <= 0;
			sys_h_count <= 0;
		end else begin
			if (sys_h_count == SYS_H_TOTAL - 1) begin
				sys_h_count <= 0;
				word_count <= 0;
				if (line_count < V_TOTAL) line_count <= line_count + 1'b1;
			end else begin
				sys_h_count <= sys_h_count + 1'b1;
			end

			// Fetch logic
			if (videoBusControl) begin
				// Fetch only if active area
				if (line_count < SYS_V_ACTIVE && word_count < 320) begin
					addr <= addr + 1'b1;
					word_count <= word_count + 1'b1;
				end
			end
		end
	end

	assign videoAddr = addr;
	// loadPixels used to gate the Write Enable in Shifter
	assign loadPixels = (line_count < SYS_V_ACTIVE && word_count < 320);

endmodule
