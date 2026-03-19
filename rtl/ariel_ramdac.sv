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
    output reg [23:0] rgb_out
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

// Dual-port palette RAM: port A = CPU, port B = video lookup
// 256 entries x 24 bits (8:8:8 RGB)
(* ramstyle = "M10K" *) reg [23:0] palette [0:255];

// Palette address counter
reg [7:0] palette_addr;
reg [1:0] color_comp; // 0=R, 1=G, 2=B
reg [7:0] control_reg;
reg [7:0] key_color;

// Latched palette entry for CPU read/modify/write of individual components
reg [23:0] palette_latch;

// Reset-based initialization
reg        init_active;
reg [8:0]  init_addr;  // 9-bit to count to 256

// Compute initial grayscale value for current init address
wire [7:0] init_shade = (init_addr[7:0] < 8'd128) ? 8'hFF :
                        (8'd255 - init_addr[7:0]) << 1;

// Video lookup (port B) - synchronous read for block RAM inference
always @(posedge clk_sys) begin
    rgb_out <= palette[pixel_index];
end

// CPU register access (matching MAME ariel.cpp behavior)
// byte_reg = {A1, ~LDS} selects register 0-3
always @(posedge clk_sys) begin
    if (reset) begin
        palette_addr <= 8'd0;
        color_comp <= 2'd0;
        control_reg <= 8'd0;
        key_color <= 8'd0;
        palette_latch <= 24'h0;
        init_active <= 1'b1;
        init_addr <= 9'd0;
    end else if (init_active) begin
        // Initialize palette from reset counter (one entry per clock)
        palette[init_addr[7:0]] <= {init_shade, init_shade, init_shade};
        if (init_addr == 9'd255)
            init_active <= 1'b0;
        init_addr <= init_addr + 9'd1;
    end else if (req) begin
        if (we) begin
            case (byte_reg)
                REG_ADDR: begin
                    // Writing address resets the R/G/B component counter
                    palette_addr <= data_in;
                    color_comp <= 2'd0;
                    // Latch current palette entry for component writes
                    palette_latch <= palette[data_in];
                end
                REG_PALETTE: begin
                    // Write to current color component, cycle through R, G, B
                    case (color_comp)
                        2'd0: begin
                            palette_latch[23:16] <= data_in;
                            palette[palette_addr] <= {data_in, palette_latch[15:0]};
                        end
                        2'd1: begin
                            palette_latch[15:8] <= data_in;
                            palette[palette_addr] <= {palette_latch[23:16], data_in, palette_latch[7:0]};
                        end
                        2'd2: begin
                            palette_latch[7:0] <= data_in;
                            palette[palette_addr] <= {palette_latch[23:8], data_in};
                        end
                        default: ;
                    endcase

                    // Auto-increment: cycle R->G->B, then advance address
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        palette_addr <= palette_addr + 8'd1;
                        // Latch next entry for subsequent writes
                        palette_latch <= palette[palette_addr + 8'd1];
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
                        2'd0: data_out <= palette_latch[23:16];
                        2'd1: data_out <= palette_latch[15:8];
                        2'd2: data_out <= palette_latch[7:0];
                        default: data_out <= 8'hFF;
                    endcase

                    // Auto-increment on read too
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        palette_addr <= palette_addr + 8'd1;
                        palette_latch <= palette[palette_addr + 8'd1];
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

endmodule
