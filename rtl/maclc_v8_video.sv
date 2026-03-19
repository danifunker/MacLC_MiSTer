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
    output reg ce_pix,

    output [7:0] palette_addr,
    input [23:0] palette_data
);

localparam [21:0] VRAM_BASE = 22'h0;  // Outputs byte offset; SDRAM base added in addrController

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

// Pixel clock enable: divide clk_sys by 2
// clk_sys=32.5MHz / 2 = 16.25MHz pixel clock (close to Mac LC's 15.6672MHz)
reg pix_div;
always @(posedge clk_sys) begin
    if (reset)
        pix_div <= 0;
    else
        pix_div <= ~pix_div;
end

wire pix_en = pix_div;

always @(posedge clk_sys) begin
    ce_pix <= pix_en;
    if (reset) begin
        h_count <= 0;
        v_count <= 0;
    end else if (pix_en) begin
        if (h_count == h_total - 1) begin
            h_count <= 0;
            v_count <= (v_count == v_total - 1) ? 10'd0 : v_count + 10'd1;
        end else
            h_count <= h_count + 11'd1;
    end
end

reg de_raw;  // Internal DE before pipeline delay

always @(posedge clk_sys) begin
    if (pix_en) begin
        hsync <= (h_count >= h_sync_start && h_count < h_sync_end);
        vsync <= (v_count >= v_sync_start && v_count < v_sync_end);
        hblank <= (h_count >= h_active);
        vblank <= (v_count >= v_active);
        de_raw <= (h_count < h_active) && (v_count < v_active);
    end
end

`ifdef SIMULATION
reg [3:0] monitor_id_prev;
reg [31:0] latch_count;
always @(posedge clk_sys) begin
    if (monitor_id != monitor_id_prev) begin
        `ifdef VERBOSE_TRACE
        $display("V8: monitor_id changed to %h @%0t", monitor_id, $time);
        `endif
        monitor_id_prev <= monitor_id;
    end
    if (reset)
        latch_count <= 0;
    else if (video_latch && !hblank && !vblank) begin
        if (latch_count < 10 || (latch_count % 100000 == 0))
            $display("V8 FETCH[%0d] @%0t: addr=%h data=%h mode=%d pixel_idx=%h palette=%h",
                latch_count, $time, video_addr, video_data_in, video_mode, pixel_index, palette_data);
        latch_count <= latch_count + 1;
    end
end
`endif

// --- Video Address Generation ---
// Row stride (bytes per scanline) depends on resolution and bpp.
// For 512-wide modes, strides are powers of 2 (64..1024).
// For 640-wide modes, strides are multiples of 80 (80..1280).
// We accumulate row_start each scanline to avoid a large multiply.

reg [10:0] row_bytes;
always @(*) begin
    case (monitor_id)
        4'h2: begin // 512x384
            case (video_mode)
                3'd0: row_bytes = 11'd64;    // 1bpp: 512/8
                3'd1: row_bytes = 11'd128;   // 2bpp
                3'd2: row_bytes = 11'd256;   // 4bpp
                3'd3: row_bytes = 11'd512;   // 8bpp
                3'd4: row_bytes = 11'd1024;  // 16bpp
                default: row_bytes = 11'd256;
            endcase
        end
        default: begin // 640x480 (and portrait)
            case (video_mode)
                3'd0: row_bytes = 11'd80;    // 1bpp: 640/8
                3'd1: row_bytes = 11'd160;   // 2bpp
                3'd2: row_bytes = 11'd320;   // 4bpp
                3'd3: row_bytes = 11'd640;   // 8bpp
                3'd4: row_bytes = 11'd1280;  // 16bpp
                default: row_bytes = 11'd320;
            endcase
        end
    endcase
end

// Accumulate row start address (byte offset of current scanline)
reg [21:0] row_start;
always @(posedge clk_sys) begin
    if (reset || (pix_en && h_count == h_total - 1 && v_count == v_total - 1))
        row_start <= 22'd0;
    else if (pix_en && h_count == h_total - 1 && v_count < v_active)
        row_start <= row_start + {11'd0, row_bytes};
end

wire [10:0] row_offset = (h_count * bits_per_pixel) >> 3; // Convert pixels to bytes
wire [10:0] fetch_addr = {row_offset[10:1], 1'b0};        // Align to 16-bit word boundary

assign video_addr = VRAM_BASE + row_start + {11'd0, fetch_addr};

reg [15:0] video_data;
reg [15:0] pixel_shift;
reg [3:0]  shift_count;

// Latch data from VRAM - capture on any clock (video_latch is 1 clk_sys wide)
// Must not be gated by pix_en or we miss 50% of latches
reg video_latch_pending;
reg [15:0] video_latch_data;

always @(posedge clk_sys) begin
    if (video_latch && !hblank && !vblank) begin
        video_data <= video_data_in;
        video_latch_data <= video_data_in;
        video_latch_pending <= 1'b1;
    end
    // Clear pending flag when consumed by shift register on pix_en
    if (pix_en && video_latch_pending && !hblank && !vblank)
        video_latch_pending <= 1'b0;
end

// --- Shift Register Logic ---
// Shift register operates at pixel clock rate (pix_en)
// We need to output 16/bits_per_pixel pixels per word
always @(posedge clk_sys) begin
    if (pix_en) begin
        if (hblank || vblank) begin
            pixel_shift <= 16'hFFFF;  // Initialize to "black" pattern for Mac
            shift_count <= 0;
        end else if (video_latch_pending) begin
            // Load new data when latch is pending
            pixel_shift <= video_latch_data;
            shift_count <= 1; // Start at 1 so first pixel displays on this clock
        end else begin
            shift_count <= shift_count + 1;

            // Shift at the start of each new pixel period
            case (bits_per_pixel)
                5'd1:  pixel_shift <= {pixel_shift[14:0], 1'b0}; // every pixel
                5'd2:  if (shift_count[0] == 0) pixel_shift <= {pixel_shift[13:0], 2'b0};
                5'd4:  if (shift_count[1:0] == 0) pixel_shift <= {pixel_shift[11:0], 4'b0};
                5'd8:  if (shift_count[2:0] == 0) pixel_shift <= {pixel_shift[7:0],  8'b0};
                5'd16: ; // No shift needed, direct color from video_data
            endcase
        end
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

// Pipeline delay: palette RAM read is synchronous (1-cycle latency),
// so delay de, video_mode, and video_data to align with palette_data output.
reg        de_d1;
reg [2:0]  video_mode_d1;
reg [15:0] video_data_d1;

always @(posedge clk_sys) begin
    de_d1         <= de_raw;
    video_mode_d1 <= video_mode;
    video_data_d1 <= video_data;
end

always @(posedge clk_sys) begin
    de <= de_d1;  // Align DE output with RGB (1-cycle palette latency)
    if (de_d1) begin
        if (video_mode_d1 == 3'd4) begin
            // 16bpp Direct Color (X-5-5-5)
            vga_r <= {video_data_d1[14:10], 3'b000};
            vga_g <= {video_data_d1[9:5],   3'b000};
            vga_b <= {video_data_d1[4:0],   3'b000};
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