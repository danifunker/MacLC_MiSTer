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

// Ariel register map
localparam REG_ADDR_LOW   = 11'h000;  // Palette address low
localparam REG_ADDR_HIGH  = 11'h001;  // Palette address high  
localparam REG_DATA       = 11'h002;  // Palette data
localparam REG_CTRL       = 11'h003;  // Control register

// 256 entry palette, 24-bit RGB (8:8:8)
reg [7:0] palette_r [0:255];
reg [7:0] palette_g [0:255];
reg [7:0] palette_b [0:255];

// Palette address counter
reg [7:0] palette_addr;
reg [1:0] color_comp; // 0=R, 1=G, 2=B
reg auto_increment;

// Initialize default grayscale palette
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1) begin
        palette_r[i] = i[7:0];
        palette_g[i] = i[7:0];
        palette_b[i] = i[7:0];
    end
end

// CPU register access
always @(posedge clk_sys) begin
    if (reset) begin
        palette_addr <= 8'd0;
        color_comp <= 2'd0;
        auto_increment <= 1'b1;
    end else if (req) begin
        if (we) begin
            case (reg_addr[1:0])
                2'd0: palette_addr <= data_in;
                2'd1: ; // High address (unused in 256-entry mode)
                2'd2: begin
                    case (color_comp)
                        2'd0: palette_r[palette_addr] <= data_in;
                        2'd1: palette_g[palette_addr] <= data_in;
                        2'd2: palette_b[palette_addr] <= data_in;
                    endcase
                    
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        if (auto_increment)
                            palette_addr <= palette_addr + 8'd1;
                    end else begin
                        color_comp <= color_comp + 2'd1;
                    end
                end
                2'd3: auto_increment <= data_in[0];
            endcase
        end else begin
            case (reg_addr[1:0])
                2'd0: data_out <= palette_addr;
                2'd2: begin
                    case (color_comp)
                        2'd0: data_out <= palette_r[palette_addr];
                        2'd1: data_out <= palette_g[palette_addr];
                        2'd2: data_out <= palette_b[palette_addr];
                        default: data_out <= 8'd0;
                    endcase
                    
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        if (auto_increment)
                            palette_addr <= palette_addr + 8'd1;
                    end else begin
                        color_comp <= color_comp + 2'd1;
                    end
                end
                default: data_out <= 8'd0;
            endcase
        end
    end
end

// Palette lookup for video
assign rgb_out = {palette_r[pixel_index], palette_g[pixel_index], palette_b[pixel_index]};

endmodule
