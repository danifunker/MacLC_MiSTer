// Mac LC V8 Video Controller - FIXED
// Supports 1, 2, 4, 8, and 16 bpp modes correctly

module maclc_v8_video(
    input clk_sys,
    input clk8_en_p,
    input reset,
    
    output [21:0] video_addr,
    input [15:0] video_data_in,
    input video_latch,
    
    input [2:0] video_mode,
    input [3:0] monitor_id,
    
    output reg hsync,
    output reg vsync,
    output reg hblank,
    output reg vblank,
 
    output reg [7:0] vga_r,
    output reg [7:0] vga_g,
    output reg [7:0] vga_b,
    output reg de,
    
    output [7:0] palette_addr,
    input [23:0] palette_data
);

localparam [21:0] VRAM_BASE = 22'h340000;

reg [10:0] h_total, h_active, h_sync_start, h_sync_end;
reg [9:0] v_total, v_active, v_sync_start, v_sync_end;

// Bits per pixel and fetch mask configuration
reg [4:0] bits_per_pixel; // 1, 2, 4, 8, 16
reg [3:0] fetch_mask;     // When to fetch new word

always @(*) begin
    case (video_mode)
        3'd0: begin bits_per_pixel = 1;  fetch_mask = 4'hF; end // 1bpp: Fetch every 16
        3'd1: begin bits_per_pixel = 2;  fetch_mask = 4'h7; end // 2bpp: Fetch every 8
        3'd2: begin bits_per_pixel = 4;  fetch_mask = 4'h3; end // 4bpp: Fetch every 4
        3'd3: begin bits_per_pixel = 8;  fetch_mask = 4'h1; end // 8bpp: Fetch every 2
        3'd4: begin bits_per_pixel = 16; fetch_mask = 4'h0; end // 16bpp: Fetch every 1
        default: begin bits_per_pixel = 1; fetch_mask = 4'hF; end
    endcase
end

always @(*) begin
    // Standard V8 monitor timings
    case (monitor_id)
        4'h1: begin // 12" RGB (512x384)
             h_total = 11'd832; h_active = 11'd640; // Note: MAME maps active to 512, but V8 uses 640 timing
             h_sync_start = 11'd656; h_sync_end = 11'd752;
             v_total = 10'd918; v_active = 10'd870;
             v_sync_start = 10'd871; v_sync_end = 10'd877;
        end
        4'h2: begin // 12" RGB Alternate
            h_total = 11'd640; h_active = 11'd512;
            h_sync_start = 11'd528; h_sync_end = 11'd576;
            v_total = 10'd407; v_active = 10'd384;
            v_sync_start = 10'd385; v_sync_end = 10'd388;
        end
        default: begin // VGA 640x480 (Monitor ID 6)
            h_total = 11'd800; h_active = 11'd640;
            h_sync_start = 11'd656; h_sync_end = 11'd752;
            v_total = 10'd525; v_active = 10'd480;
            v_sync_start = 10'd490; v_sync_end = 10'd492;
        end
    endcase
end

reg [10:0] h_count;
reg [9:0] v_count;

always @(posedge clk_sys) begin
    if (reset) begin
        h_count <= 0;
        v_count <= 0;
    end else begin
        if (h_count == h_total - 1) begin
            h_count <= 0;
            v_count <= (v_count == v_total - 1) ? 10'd0 : v_count + 10'd1;
        end else
            h_count <= h_count + 11'd1;
    end
end

always @(posedge clk_sys) begin
    hsync <= (h_count >= h_sync_start && h_count < h_sync_end);
    vsync <= (v_count >= v_sync_start && v_count < v_sync_end);
    hblank <= (h_count >= h_active);
    vblank <= (v_count >= v_active);
    de <= (h_count < h_active) && (v_count < v_active);
end

// --- Video Address Generation ---
// VRAM Stride is 1024 bytes (0x400)
// We calculate the byte offset of the current pixel group
// h_count must be masked to align with the fetch width (16, 8, 4, or 2 bytes)
// However, since we fetch 16-bit words, we just multiply h_count by BPP/8
// Simplified: Address = Base + (Y * 1024) + (X * BPP / 8)
// Since video_data_in is 16-bit, we want to align to even bytes.

wire [10:0] row_offset = (h_count * bits_per_pixel) >> 3; // Convert pixels to bytes
wire [10:0] fetch_addr = {row_offset[10:1], 1'b0};        // Align to 16-bit word boundary

// VRAM_BASE + (v_count * 1024) + offset
assign video_addr = VRAM_BASE + {v_count, 10'd0} + {11'd0, fetch_addr};

reg [15:0] video_data;
reg [15:0] pixel_shift;
reg [3:0]  shift_count;

// Latch data from VRAM - keep for 16bpp direct access
always @(posedge clk_sys) begin
    if (video_latch && !hblank && !vblank)
        video_data <= video_data_in;
end

// --- Shift Register Logic ---
// video_latch occurs once per 16 clocks (bus cycle period)
// We need to output 16/bits_per_pixel pixels per word
// So shift interval is bits_per_pixel clocks (1bpp: every clock, 4bpp: every 4 clocks)
always @(posedge clk_sys) begin
    if (hblank || vblank) begin
        pixel_shift <= 16'd0;
        shift_count <= 0;
    end else if (video_latch) begin
        // Load new data directly when it arrives
        pixel_shift <= video_data_in;
        shift_count <= 1; // Start at 1 so first pixel displays on this clock
    end else begin
        shift_count <= shift_count + 1;

        // Shift at the start of each new pixel period
        // For N bits per pixel, shift every (16/pixels_per_word) = N clocks
        // Check uses current shift_count value, shift happens at counts 4,8,12 for 4bpp etc.
        case (bits_per_pixel)
            5'd1:  pixel_shift <= {pixel_shift[14:0], 1'b0}; // every clock
            5'd2:  if (shift_count[0] == 0) pixel_shift <= {pixel_shift[13:0], 2'b0}; // every 2 clocks
            5'd4:  if (shift_count[1:0] == 0) pixel_shift <= {pixel_shift[11:0], 4'b0}; // every 4 clocks
            5'd8:  if (shift_count[2:0] == 0) pixel_shift <= {pixel_shift[7:0],  8'b0}; // every 8 clocks
            5'd16: ; // No shift needed, direct color from video_data
        endcase
    end
end

reg [7:0] pixel_index;

// --- Pixel Extraction ---
// We extract from the MSB (Big Endian Mac format)
// MAME uses specific palette index patterns:
// 1bpp: 0x7F | (bit ? 0x80 : 0) → 0x7F (white) or 0xFF (black)
// 2bpp: 0x3F | (2-bit << 6) → 0x3F, 0x7F, 0xBF, 0xFF
// 4bpp: 0x0F | (4-bit << 4) → 0x0F, 0x1F, 0x2F, ..., 0xFF
// 8bpp: direct 0x00-0xFF
always @(*) begin
    case (video_mode)
        3'd0: pixel_index = {pixel_shift[15], 7'b1111111};            // 1bpp: 0x7F or 0xFF
        3'd1: pixel_index = {pixel_shift[15:14], 6'b111111};          // 2bpp: 0x3F, 0x7F, 0xBF, 0xFF
        3'd2: pixel_index = {pixel_shift[15:12], 4'b1111};            // 4bpp: 0x0F-0xFF
        3'd3: pixel_index = pixel_shift[15:8];                        // 8bpp: direct
        default: pixel_index = 8'd0;
    endcase
end

assign palette_addr = pixel_index;

always @(posedge clk_sys) begin
    if (de) begin
        if (video_mode == 3'd4) begin
            // 16bpp Direct Color (X-5-5-5)
            // Note: Use 'video_data' directly here or ensure pixel_shift is loaded correctly
            // For 16bpp, we fetch every cycle, so video_data is the pixel.
            vga_r <= {video_data[14:10], 3'b000};
            vga_g <= {video_data[9:5],   3'b000};
            vga_b <= {video_data[4:0],   3'b000};
        end else begin
            // Palette Lookup
            vga_r <= palette_data[23:16];
            vga_g <= palette_data[15:8];
            vga_b <= palette_data[7:0];
        end
    end else begin
        vga_r <= 8'd0;
        vga_g <= 8'd0;
        vga_b <= 8'd0;
    end
end

endmodule