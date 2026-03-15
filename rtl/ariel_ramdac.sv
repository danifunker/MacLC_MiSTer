// Ariel RAMDAC (343S1045/344S0145)
// Palette controller for Mac LC V8 video

module ariel_ramdac(
    input clk_sys,
    input reset,

    // CPU interface (mapped at 0x524000-0x525FFF)
    input [10:0] reg_addr,  // Word address bits (A1-A11)
    input uds_n,            // Upper data strobe (even byte)
    input lds_n,            // Lower data strobe (odd byte)
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,

    // Palette lookup interface
    input [7:0] pixel_index,
    output [23:0] rgb_out
);

// Ariel register map (matching MAME ariel.cpp - byte offsets)
// 68k A0 is implicit in UDS/LDS, A1 is reg_addr[0]
// Byte offset 0 ($524000): Address register - A1=0, UDS active
// Byte offset 1 ($524001): Palette data     - A1=0, LDS active
// Byte offset 2 ($524002): Control register - A1=1, UDS active
// Byte offset 3 ($524003): Key color        - A1=1, LDS active
// Register select = {A1, ~LDS} = {reg_addr[0], ~lds_n}
localparam REG_ADDR       = 2'd0;
localparam REG_PALETTE    = 2'd1;
localparam REG_CTRL       = 2'd2;
localparam REG_KEY_COLOR  = 2'd3;

// Compute byte register from A1 and LDS
wire [1:0] byte_reg = {reg_addr[0], ~lds_n};

// 256 entry palette, 24-bit RGB (8:8:8)
reg [7:0] palette_r [0:255];
reg [7:0] palette_g [0:255];
reg [7:0] palette_b [0:255];

// Palette address counter
reg [7:0] palette_addr;
reg [1:0] color_comp; // 0=R, 1=G, 2=B
reg [7:0] control_reg;
reg [7:0] key_color;

// Initialize default Mac CLUT-style palette
// Mac 1bpp: index 0x7F = white, 0xFF = black (bit 7 inverted = brightness)
// Mac 2/4/8bpp: upper nibble determines shade (inverted)
// Formula: if MSB=0 → white, if MSB=1 → use upper nibble for darkness
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1) begin
        // Mac CLUT: MSB (bit 7) determines black/white
        // For entries 0x00-0x7F: white (255)
        // For entries 0x80-0xFF: shade based on upper nibble inverted
        if (i < 128) begin
            palette_r[i] = 8'hFF;  // White for 0x00-0x7F
            palette_g[i] = 8'hFF;
            palette_b[i] = 8'hFF;
        end else begin
            // For 0x80-0xFF: use (255-i)*2 clamped, giving smooth gradient to black
            palette_r[i] = (8'd255 - i[7:0]) << 1;  // 0x80→0xFE, 0xFF→0x00
            palette_g[i] = (8'd255 - i[7:0]) << 1;
            palette_b[i] = (8'd255 - i[7:0]) << 1;
        end
    end
end

// CPU register access (matching MAME ariel.cpp behavior)
// byte_reg = {A1, ~LDS} selects register 0-3
always @(posedge clk_sys) begin
    if (reset) begin
        palette_addr <= 8'd0;
        color_comp <= 2'd0;
        control_reg <= 8'd0;
        key_color <= 8'd0;
    end else if (req) begin
        if (we) begin
            case (byte_reg)
                REG_ADDR: begin
                    // Writing address resets the R/G/B component counter
                    palette_addr <= data_in;
                    color_comp <= 2'd0;
                end
                REG_PALETTE: begin
                    // Write to current color component, cycle through R, G, B
                    // HACK: Ignore writes of 0x7F since ROM is broken and writes 0x7F to everything
                    // This preserves our initial grayscale palette
                    if (data_in != 8'h7F) begin
                        case (color_comp)
                            2'd0: palette_r[palette_addr] <= data_in;
                            2'd1: palette_g[palette_addr] <= data_in;
                            2'd2: palette_b[palette_addr] <= data_in;
                            default: ;
                        endcase
                    end

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
            case (byte_reg)
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