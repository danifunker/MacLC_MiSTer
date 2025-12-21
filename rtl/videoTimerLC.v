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
	output loadPixels // Used to signal Shifter? Actually Shifter should monitor FIFO.
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
	// We only fetch active video data.
	// Reset address at VSync.

	// Cross VSync to System Domain
	reg vsync_sys_1, vsync_sys_2;
	always @(posedge clk_sys) begin
		vsync_sys_1 <= v_sync_active; // Active high internal
		vsync_sys_2 <= vsync_sys_1;
	end

	wire vsync_start = vsync_sys_1 && !vsync_sys_2;

	reg [21:0] addr;

	always @(posedge clk_sys) begin
		if (vsync_start) begin
			addr <= 0;
		end else if (videoBusControl) begin
			addr <= addr + 1'b1;
		end
	end

	assign videoAddr = addr;
	assign loadPixels = 0;

endmodule
