// Mac LC V8 Video Controller - SDRAM-based VRAM
// VRAM stored in SDRAM like Mac Plus framebuffer
// Video fetches during videoBusControl cycles

module maclc_v8_video(
    input clk_sys,
    input clk8_en_p,
    input reset,
    
    // Video memory fetch (connects to memoryDataIn during videoBusControl)
    output [21:0] video_addr,
    input [15:0] video_data_in,
    input video_latch,  // memoryLatch signal
    
    // Configuration
    input [2:0] video_mode,   // 0=1bpp, 1=2bpp, 2=4bpp, 3=8bpp, 4=16bpp
    input [3:0] monitor_id,   // Monitor type
    
    // Video output
    output reg hsync,
    output reg vsync,
    output reg hblank,
    output reg vblank,
    output reg [7:0] vga_r,
    output reg [7:0] vga_g,
    output reg [7:0] vga_b,
    output reg de,
    
    // Palette interface
    output [7:0] palette_addr,
    input [23:0] palette_data
);

// VRAM base in SDRAM
// Use same area as Mac Plus but different offset
localparam [21:0] VRAM_BASE = 22'h3FA900;

// Video timing
reg [10:0] h_total, h_active, h_sync_start, h_sync_end;
reg [9:0] v_total, v_active, v_sync_start, v_sync_end;

always @(*) begin
    case (monitor_id)
        4'h1: begin // 640x870
            h_total = 11'd832; h_active = 11'd640;
            h_sync_start = 11'd656; h_sync_end = 11'd752;
            v_total = 10'd918; v_active = 10'd870;
            v_sync_start = 10'd871; v_sync_end = 10'd877;
        end
        4'h2: begin // 512x384
            h_total = 11'd640; h_active = 11'd512;
            h_sync_start = 11'd528; h_sync_end = 11'd576;
            v_total = 10'd407; v_active = 10'd384;
            v_sync_start = 10'd385; v_sync_end = 10'd388;
        end
        default: begin // 640x480
            h_total = 11'd800; h_active = 11'd640;
            h_sync_start = 11'd656; h_sync_end = 11'd752;
            v_total = 10'd525; v_active = 10'd480;
            v_sync_start = 10'd490; v_sync_end = 10'd492;
        end
    endcase
end

// Counters
reg [10:0] h_count;
reg [9:0] v_count;

always @(posedge clk_sys) begin
    if (reset) begin
        h_count <= 0;
        v_count <= 0;
    end else if (clk8_en_p) begin
        if (h_count == h_total - 1) begin
            h_count <= 0;
            v_count <= (v_count == v_total - 1) ? 10'd0 : v_count + 10'd1;
        end else
            h_count <= h_count + 11'd1;
    end
end

// Sync signals
always @(posedge clk_sys) begin
    if (clk8_en_p) begin
        hsync <= (h_count >= h_sync_start && h_count < h_sync_end);
        vsync <= (v_count >= v_sync_start && v_count < v_sync_end);
        hblank <= (h_count >= h_active);
        vblank <= (v_count >= v_active);
        de <= (h_count < h_active) && (v_count < v_active);
    end
end

// Video address (1024 byte stride per scanline)
assign video_addr = VRAM_BASE + {v_count, h_count[10:1], 1'b0};

// Latch video data
reg [15:0] video_data;
always @(posedge clk_sys) begin
    if (video_latch)
        video_data <= video_data_in;
end

// Pixel extraction (simple implementation)
reg [7:0] pixel_index;
wire [3:0] bit_sel = h_count[0] ? 4'd0 : 4'd8;

always @(*) begin
    case (video_mode)
        3'd0: pixel_index = video_data[15 - h_count[3:0]] ? 8'hFF : 8'h00; // 1bpp
        3'd1: pixel_index = {6'h3F, video_data[15 - {h_count[2:0], 1'b0} +: 2]}; // 2bpp
        3'd2: pixel_index = {4'h0F, video_data[15 - {h_count[1:0], 2'b00} +: 4]}; // 4bpp
        3'd3: pixel_index = video_data[15 - bit_sel +: 8]; // 8bpp
        default: pixel_index = 8'h00;
    endcase
end

assign palette_addr = pixel_index;

// RGB output
always @(posedge clk_sys) begin
    if (clk8_en_p && de) begin
        if (video_mode == 3'd4) begin // 16bpp direct (5:5:5)
            vga_r <= {video_data[14:10], 3'b000};
            vga_g <= {video_data[9:5], 3'b000};
            vga_b <= {video_data[4:0], 3'b000};
        end else begin
            vga_r <= palette_data[23:16];
            vga_g <= palette_data[15:8];
            vga_b <= palette_data[7:0];
        end
    end else if (clk8_en_p) begin
        vga_r <= 8'd0;
        vga_g <= 8'd0;
        vga_b <= 8'd0;
    end
end

endmodule