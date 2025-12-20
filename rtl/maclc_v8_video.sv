// Mac LC V8 Video Controller
// Based on MAME v8.cpp implementation
// Supports 256KB/512KB VRAM with 1/2/4/8/16bpp modes

module maclc_v8_video(
    input clk_sys,
    input clk8_en_p,
    input reset,
    
    // CPU interface for VRAM access
    input [17:0] vram_addr,        // 0x540000-0x57FFFF mapped to VRAM
    input [31:0] vram_din,
    output [31:0] vram_dout,
    input [3:0] vram_be,
    input vram_we,
    input vram_req,
    
    // Configuration
    input vram_512kb,              // 0=256KB, 1=512KB
    input [2:0] video_mode,        // From VIA2: 0=1bpp, 1=2bpp, 2=4bpp, 3=8bpp, 4=16bpp
    input [3:0] monitor_id,        // Monitor type
    
    // Video output
    output reg hsync,
    output reg vsync,
    output reg hblank,
    output reg vblank,
    output reg [7:0] vga_r,
    output reg [7:0] vga_g,
    output reg [7:0] vga_b,
    output reg de,
    
    // Ariel palette interface (256 colors, 24-bit RGB)
    output [7:0] palette_addr,
    input [23:0] palette_data
);

// Video timing parameters based on monitor ID
reg [10:0] h_total, h_active, h_sync_start, h_sync_end;
reg [9:0] v_total, v_active, v_sync_start, v_sync_end;
reg [10:0] h_res;
reg [9:0] v_res;

always @(*) begin
    case (monitor_id)
        4'h1: begin // 15" Portrait 640x870
            h_total = 11'd832;
            h_active = 11'd640;
            h_sync_start = 11'd656;
            h_sync_end = 11'd752;
            v_total = 10'd918;
            v_active = 10'd870;
            v_sync_start = 10'd871;
            v_sync_end = 10'd877;
            h_res = 11'd640;
            v_res = 10'd870;
        end
        4'h2: begin // 12" RGB 512x384
            h_total = 11'd640;
            h_active = 11'd512;
            h_sync_start = 11'd528;
            h_sync_end = 11'd576;
            v_total = 10'd407;
            v_active = 10'd384;
            v_sync_start = 10'd385;
            v_sync_end = 10'd388;
            h_res = 11'd512;
            v_res = 10'd384;
        end
        default: begin // 13" RGB 640x480 (most common)
            h_total = 11'd800;
            h_active = 11'd640;
            h_sync_start = 11'd656;
            h_sync_end = 11'd752;
            v_total = 10'd525;
            v_active = 10'd480;
            v_sync_start = 10'd490;
            v_sync_end = 10'd492;
            h_res = 11'd640;
            v_res = 10'd480;
        end
    endcase
end

// Horizontal and vertical counters
reg [10:0] h_count;
reg [9:0] v_count;

always @(posedge clk_sys) begin
    if (reset) begin
        h_count <= 0;
        v_count <= 0;
    end else if (clk8_en_p) begin
        if (h_count == h_total - 1) begin
            h_count <= 0;
            if (v_count == v_total - 1)
                v_count <= 0;
            else
                v_count <= v_count + 1'd1;
        end else begin
            h_count <= h_count + 1'd1;
        end
    end
end

// Sync generation
always @(posedge clk_sys) begin
    if (clk8_en_p) begin
        hsync <= (h_count >= h_sync_start && h_count < h_sync_end);
        vsync <= (v_count >= v_sync_start && v_count < v_sync_end);
        hblank <= (h_count >= h_active);
        vblank <= (v_count >= v_active);
        de <= (h_count < h_active) && (v_count < v_active);
    end
end

// VRAM - dual port: CPU port + Video port
// 512KB = 128K x 32-bit words
// 256KB = 64K x 32-bit words
reg [31:0] vram [0:131071]; // 512KB max

// CPU port
wire [16:0] cpu_vram_addr = vram_addr[17:1]; // Word address
always @(posedge clk_sys) begin
    if (vram_req && vram_we) begin
        if (vram_be[0]) vram[cpu_vram_addr][7:0] <= vram_din[7:0];
        if (vram_be[1]) vram[cpu_vram_addr][15:8] <= vram_din[15:8];
        if (vram_be[2]) vram[cpu_vram_addr][23:16] <= vram_din[23:16];
        if (vram_be[3]) vram[cpu_vram_addr][31:24] <= vram_din[31:24];
    end
end

assign vram_dout = vram[cpu_vram_addr];

// Video fetch address calculation
// Scanline base: y * 1024 bytes (stride)
wire [16:0] line_base = v_count * 17'd1024;
wire [16:0] video_fetch_addr = (line_base + {7'b0, h_count[10:1]}) >> 2; // Byte to word

// Video port - prefetch for pixel pipeline
reg [31:0] video_data;
reg [31:0] video_data_d;
always @(posedge clk_sys) begin
    if (clk8_en_p && !vblank) begin
        video_data <= vram[video_fetch_addr];
        video_data_d <= video_data;
    end
end

// Pixel extraction based on mode
reg [7:0] pixel_index;
wire [31:0] pixel_source = h_count[0] ? video_data_d : video_data;
wire [10:0] x_pos = h_count;

always @(*) begin
    case (video_mode)
        3'd0: begin // 1bpp
            pixel_index = pixel_source[31 - (x_pos[2:0])] ? 8'hFF : 8'h00;
        end
        3'd1: begin // 2bpp
            case (x_pos[1:0])
                2'd0: pixel_index = {6'h3F, pixel_source[31:30]};
                2'd1: pixel_index = {6'h3F, pixel_source[29:28]};
                2'd2: pixel_index = {6'h3F, pixel_source[27:26]};
                2'd3: pixel_index = {6'h3F, pixel_source[25:24]};
            endcase
        end
        3'd2: begin // 4bpp
            pixel_index = x_pos[0] ? {4'h0F, pixel_source[27:24]} : {4'h0F, pixel_source[31:28]};
        end
        3'd3: begin // 8bpp
            case (x_pos[1:0])
                2'd0: pixel_index = pixel_source[31:24];
                2'd1: pixel_index = pixel_source[23:16];
                2'd2: pixel_index = pixel_source[15:8];
                2'd3: pixel_index = pixel_source[7:0];
            endcase
        end
        3'd4: begin // 16bpp - direct color (5:5:5)
            pixel_index = 8'd0; // Not indexed, handled separately
        end
        default: pixel_index = 8'd0;
    endcase
end

assign palette_addr = pixel_index;

// RGB output
always @(posedge clk_sys) begin
    if (clk8_en_p) begin
        if (de) begin
            if (video_mode == 3'd4) begin
                // 16bpp direct color (1:5:5:5 format)
                case (x_pos[0])
                    1'b0: begin
                        vga_r <= {pixel_source[26:22], 3'b000};
                        vga_g <= {pixel_source[21:17], 3'b000};
                        vga_b <= {pixel_source[16:12], 3'b000};
                    end
                    1'b1: begin
                        vga_r <= {pixel_source[10:6], 3'b000};
                        vga_g <= {pixel_source[5:1], 3'b000};
                        vga_b <= {pixel_source[15:11], 3'b000};
                    end
                endcase
            end else begin
                // Indexed color through palette
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
end

endmodule
