module videoTimerLC(
	input clk,
	input clk_en,
	input [1:0] busCycle,
	output [21:0] videoAddr,
	output reg hsync,
	output reg vsync,
	output _hblank,
	output _vblank,
	output loadPixels
);

	// VGA 640x480 @ 60Hz parameters
	// Pixel Clock: 25.175 MHz.
	// Input Clock: 32.5 MHz (clk_sys).
	// We need to approximate the timing or run at higher refresh.
	// Running at 32.5 MHz with standard VGA counts will result in ~77Hz refresh.

	localparam H_VISIBLE = 640;
	localparam H_FRONT   = 16;
	localparam H_SYNC    = 96;
	localparam H_BACK    = 48;
	localparam H_TOTAL   = 800;

	localparam V_VISIBLE = 480;
	localparam V_FRONT   = 10;
	localparam V_SYNC    = 2;
	localparam V_BACK    = 33;
	localparam V_TOTAL   = 525;

	// Assuming 1 pixel per clock for now (32.5 MHz)
	// Or we can try to use a clock enable to slow it down.
	// 32.5 / 25.175 = 1.29.
	// Maybe just run fast for now.

	reg [9:0] h_cnt;
	reg [9:0] v_cnt;

	always @(posedge clk) begin
		if (clk_en) begin
			if (h_cnt == H_TOTAL - 1) begin
				h_cnt <= 0;
				if (v_cnt == V_TOTAL - 1)
					v_cnt <= 0;
				else
					v_cnt <= v_cnt + 1;
			end else begin
				h_cnt <= h_cnt + 1;
			end
		end
	end

	always @(posedge clk) begin
		hsync <= ~(h_cnt >= (H_VISIBLE + H_FRONT) && h_cnt < (H_VISIBLE + H_FRONT + H_SYNC));
		vsync <= ~(v_cnt >= (V_VISIBLE + V_FRONT) && v_cnt < (V_VISIBLE + V_FRONT + V_SYNC));
	end

	assign _hblank = (h_cnt < H_VISIBLE);
	assign _vblank = (v_cnt < V_VISIBLE);

	// Load pixels when visible
	// 8bpp = 1 byte per pixel. 16-bit word = 2 pixels.
	// We need to load a new word every 2 clocks.

	reg load_toggle;
	always @(posedge clk) begin
		if (clk_en) load_toggle <= ~load_toggle;
	end

	assign loadPixels = _hblank && _vblank && load_toggle;

	// VRAM Address
	// VRAM starts at 0 relative to video base.
	// Address is in 16-bit words.
	// 640 pixels / 2 = 320 words per line.
	// Address = v_cnt * 320 + h_cnt / 2;

	// Optimization: 320 = 256 + 64.
	wire [21:0] row_addr = {v_cnt, 8'b0} + {v_cnt, 6'b0};
	assign videoAddr = row_addr + (h_cnt[9:1]);

endmodule
