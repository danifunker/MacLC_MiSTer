// Ariel RAMDAC (343S1045/344S0145)
// Palette controller for Mac LC V8 video

module ariel_ramdac(
    input clk_sys,
    input reset,
    
    // CPU interface (mapped at 0x524000-0x525FFF)
    input [10:0] reg_addr,
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,
    
    // Palette lookup interface
    input [7:0] pixel_index,
    output [23:0] rgb_out
);

// Ariel register map (matching MAME ariel.cpp)
// Using word-aligned addresses (68k A1 selects register):
// Byte offset 0 (0x524000): Address register (R/W)
// Byte offset 2 (0x524002): Palette data (R/W, auto-increments through R, G, B)
// Byte offset 4 (0x524004): Control register (R/W) - bits 0-2 = depth, bit 3 = master
// Byte offset 6 (0x524006): Key color register (R/W)
localparam REG_ADDR       = 2'd0;
localparam REG_PALETTE    = 2'd1;
localparam REG_CTRL       = 2'd2;
localparam REG_KEY_COLOR  = 2'd3;

// 256 entry palette, 24-bit RGB (8:8:8)
reg [7:0] palette_r [0:255];
reg [7:0] palette_g [0:255];
reg [7:0] palette_b [0:255];

// Palette address counter
reg [7:0] palette_addr;
reg [1:0] color_comp; // 0=R, 1=G, 2=B
reg [7:0] control_reg;
reg [7:0] key_color;

// Initialize default grayscale palette
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1) begin
        palette_r[i] = i[7:0];
        palette_g[i] = i[7:0];
        palette_b[i] = i[7:0];
    end
end

// Debug: track if we ever get a request
integer ariel_req_count = 0;

// CPU register access (matching MAME ariel.cpp behavior)
// Note: 68k only outputs A1-A23, so we use reg_addr[2:1] to decode
// word-aligned addresses (at byte offsets 0, 2, 4, 6 from base)
always @(posedge clk_sys) begin
    if (req && ariel_req_count < 50) begin
        $display("ARIEL %s: full_addr=%03x reg=%d data=%02x",
                 we ? "WR" : "RD", reg_addr, reg_addr[2:1], we ? data_in : data_out);
        ariel_req_count <= ariel_req_count + 1;
    end
    if (reset) begin
        palette_addr <= 8'd0;
        color_comp <= 2'd0;
        control_reg <= 8'd0;
        key_color <= 8'd0;
    end else if (req) begin
        if (we) begin
            case (reg_addr[2:1])
                REG_ADDR: begin
                    // Writing address resets the R/G/B component counter
                    palette_addr <= data_in;
                    color_comp <= 2'd0;
                end
                REG_PALETTE: begin
                    // Write to current color component, cycle through R, G, B
                    case (color_comp)
                        2'd0: begin
                            palette_r[palette_addr] <= data_in;
                            // Debug first few palette writes
                            if (palette_addr < 20)
                                $display("ARIEL: palette[%0d].R = %02x", palette_addr, data_in);
                        end
                        2'd1: begin
                            palette_g[palette_addr] <= data_in;
                            if (palette_addr < 20)
                                $display("ARIEL: palette[%0d].G = %02x", palette_addr, data_in);
                        end
                        2'd2: begin
                            palette_b[palette_addr] <= data_in;
                            if (palette_addr < 20)
                                $display("ARIEL: palette[%0d].B = %02x", palette_addr, data_in);
                        end
                        default: ;
                    endcase

                    // Auto-increment: cycle R->G->B, then advance address
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        palette_addr <= palette_addr + 8'd1;
                    end else begin
                        color_comp <= color_comp + 2'd1;
                    end
                end
                REG_CTRL: control_reg <= data_in;
                REG_KEY_COLOR: key_color <= data_in;
            endcase
        end else begin
            // Read registers
            case (reg_addr[2:1])
                REG_ADDR: begin
                    data_out <= palette_addr;
                    color_comp <= 2'd0;  // Reading address also resets component counter
                end
                REG_PALETTE: begin
                    case (color_comp)
                        2'd0: data_out <= palette_r[palette_addr];
                        2'd1: data_out <= palette_g[palette_addr];
                        2'd2: data_out <= palette_b[palette_addr];
                        default: data_out <= 8'hFF;
                    endcase

                    // Auto-increment on read too
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        palette_addr <= palette_addr + 8'd1;
                    end else begin
                        color_comp <= color_comp + 2'd1;
                    end
                end
                REG_CTRL: data_out <= control_reg;
                REG_KEY_COLOR: data_out <= key_color;
            endcase
        end
    end
end

// Palette lookup for video
assign rgb_out = {palette_r[pixel_index], palette_g[pixel_index], palette_b[pixel_index]};

endmodule