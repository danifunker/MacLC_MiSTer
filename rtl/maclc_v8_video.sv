// Mac LC V8 Video Controller - CORRECTED
// Runs at full 32MHz system clock for proper 25MHz pixel rate

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

always @(*) begin
    case (monitor_id)
        4'h1: begin
            h_total = 11'd832; h_active = 11'd640;
            h_sync_start = 11'd656; h_sync_end = 11'd752;
            v_total = 10'd918; v_active = 10'd870;
            v_sync_start = 10'd871; v_sync_end = 10'd877;
        end
        4'h2: begin
            h_total = 11'd640; h_active = 11'd512;
            h_sync_start = 11'd528; h_sync_end = 11'd576;
            v_total = 10'd407; v_active = 10'd384;
            v_sync_start = 10'd385; v_sync_end = 10'd388;
        end
        default: begin
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

// Video address - 1024 byte row stride, fetch every 16 pixels
wire [10:0] fetch_x = {h_count[10:4], 4'b0000};
assign video_addr = VRAM_BASE + {v_count, fetch_x[10:1], 1'b0};

reg [15:0] video_data;
always @(posedge clk_sys) begin
    if (video_latch && !hblank && !vblank)
        video_data <= video_data_in;
end

reg [15:0] pixel_shift;
reg [3:0] pixel_count;

always @(posedge clk_sys) begin
    if (hblank || vblank) begin
        pixel_shift <= 16'd0;
        pixel_count <= 4'd0;
    end else begin
        if (h_count[3:0] == 4'd0) begin
            pixel_shift <= video_data;
            pixel_count <= 4'd15;
        end else begin
            pixel_shift <= {pixel_shift[14:0], 1'b0};
            if (pixel_count != 0)
                pixel_count <= pixel_count - 4'd1;
        end
    end
end

reg [7:0] pixel_index;

always @(*) begin
    case (video_mode)
        3'd0: pixel_index = pixel_shift[15] ? 8'hFF : 8'h00;
        3'd1: pixel_index = {6'b111111, pixel_shift[15:14]};
        3'd2: pixel_index = {4'b1111, pixel_shift[15:12]};
        3'd3: pixel_index = pixel_shift[15:8];
        default: pixel_index = 8'd0;
    endcase
end

assign palette_addr = pixel_index;

always @(posedge clk_sys) begin
    if (de) begin
        if (video_mode == 3'd4) begin
            vga_r <= {pixel_shift[14:10], 3'b000};
            vga_g <= {pixel_shift[9:5], 3'b000};
            vga_b <= {pixel_shift[4:0], 3'b000};
        end else begin
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