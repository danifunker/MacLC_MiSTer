// Mac LC Pseudo-VIA - CORRECTED
// Mapped at 0x526000-0x527FFF in V8
// Register Stride is 512 bytes (0x200)

module pseudovia(
    input clk_sys,
    input reset,
    
    // CPU interface
    // Expanded to 13 bits to handle 0x1C00 max offset
    input [12:0] addr, 
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,
    
    // Interrupts
    input vblank_irq,
    input slot_irq,
    output reg irq_out,
    
    // Config
    input [1:0] ram_config,  // 0=128K, 1=512K, 2=1MB, 3=4MB
    input [3:0] monitor_id
);

// Register map (Stride 0x200)
localparam REG_VPORB    = 13'h0000; // Reg 0: Port B
localparam REG_VDIRB    = 13'h0400; // Reg 2: Port B Direction
localparam REG_CONFIG   = 13'h1000; // Reg 8: RAM Config (V8 specific)
localparam REG_VIDEO    = 13'h1400; // Reg 10: Video Config (V8 specific)
localparam REG_VIFR     = 13'h1A00; // Reg 13: Interrupt Flag
localparam REG_VIER     = 13'h1C00; // Reg 14: Interrupt Enable

reg [7:0] port_b;
reg [7:0] dir_b;
reg [7:0] ifr; // Bits 0-6 are flags, Bit 7 is Summary
reg [7:0] ier; // Bits 0-6 are masks, Bit 7 is Set/Clear control
reg [7:0] config_reg;
reg [7:0] video_config;

// Interrupt flags (V8/Eagle specific)
// Bit 6: VBlank
// Bit 5: Slot IRQ (PDS)
wire vbl_flag = vblank_irq;
wire slot_flag = slot_irq;

// Interrupt Summary Logic
wire [6:0] active_irqs = ifr[6:0] & ier[6:0];
wire irq_pending = |active_irqs;

always @(posedge clk_sys) begin
    if (reset) begin
        port_b <= 8'h00;
        dir_b <= 8'h00;
        ifr <= 8'h00;
        ier <= 8'h00;
        config_reg <= 8'h00;
        video_config <= 8'h00;
        irq_out <= 1'b0;
    end else begin
        // Update interrupt flags (Set on rising edge of input)
        // Note: Real VIA uses edge detection, here we assume pulse or level handled by top
        if (vbl_flag) ifr[6] <= 1'b1;
        if (slot_flag) ifr[5] <= 1'b1;
        
        // Update IRQ Output
        irq_out <= irq_pending;
        
        // Update Summary Bit (Read-only status)
        ifr[7] <= irq_pending;

        if (req) begin
            if (we) begin
                case (addr)
                    REG_VPORB: port_b <= data_in;
                    REG_VDIRB: dir_b <= data_in;
                    REG_CONFIG: config_reg <= data_in;
                    REG_VIDEO:  video_config <= data_in;
                    
                    REG_VIFR: begin 
                        // Write 1 to clear specific bits (Standard VIA)
                        // Note: Bit 7 is ignored on write
                        ifr[6:0] <= ifr[6:0] & ~data_in[6:0];
                    end
                    
                    REG_VIER: begin
                        // Bit 7 controls Set (1) or Clear (0)
                        if (data_in[7])
                            ier[6:0] <= ier[6:0] | data_in[6:0];
                        else
                            ier[6:0] <= ier[6:0] & ~data_in[6:0];
                    end
                    default: ;
                endcase
            end else begin
                // Read Logic
                case (addr)
                    REG_VPORB: data_out <= port_b;
                    REG_VDIRB: data_out <= dir_b;
                    REG_VIFR:  data_out <= ifr; // Returns calculated summary bit 7
                    REG_VIER:  data_out <= {1'b1, ier[6:0]}; // Bit 7 always 1 on read
                    
                    REG_CONFIG: begin
                        // Return RAM size | 0x04 (bit 2 always set in V8)
                        case (ram_config)
                            2'b00: data_out <= 8'h04; // 128K
                            2'b01: data_out <= 8'h05; // 512K
                            2'b10: data_out <= 8'h06; // 1MB
                            2'b11: data_out <= 8'h07; // 4MB
                        endcase
                    end
                    
                    REG_VIDEO: begin
                         // Monitor ID in bits 5:3
                        data_out <= {2'b00, monitor_id, 3'b000};
                    end
                    
                    default: data_out <= 8'hFF;
                endcase
            end
        end
    end
end

endmodule