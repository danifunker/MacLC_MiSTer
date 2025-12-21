// Mac LC Pseudo-VIA
// Simplified VIA-like device in V8 ASIC at 0x526000-0x527FFF

module pseudovia(
    input clk_sys,
    input reset,
    
    // CPU interface
    input [10:0] addr,
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

// Register map (VIA-like but simplified)
localparam REG_VPORB    = 11'h000;  // Port B output
localparam REG_VDIRB    = 11'h400;  // Port B direction
localparam REG_VIFR     = 11'hD00;  // Interrupt flag
localparam REG_VIER     = 11'hE00;  // Interrupt enable
localparam REG_CONFIG   = 11'h1000; // RAM config register
localparam REG_VIDEO    = 11'h1400; // Video config register

reg [7:0] port_b;
reg [7:0] dir_b;
reg [7:0] ifr;
reg [7:0] ier;
reg [7:0] config_reg;
reg [7:0] video_config;

// Interrupt flags
wire vbl_flag = vblank_irq;
wire slot_flag = slot_irq;

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
        // Update interrupt flags
        if (vbl_flag) ifr[6] <= 1'b1;
        if (slot_flag) ifr[5] <= 1'b1;
        
        // Generate IRQ
        irq_out <= |(ifr[6:0] & ier[6:0]);
        
        if (req) begin
            if (we) begin
                case (addr[10:8])
                    3'h0: port_b <= data_in;
                    3'h4: dir_b <= data_in;
                    3'h6: begin  // IFR - write 1 to clear
                        if (data_in[6]) ifr[6] <= 1'b0;
                        if (data_in[5]) ifr[5] <= 1'b0;
                    end
                    3'h7: begin  // IER
                        if (data_in[7])
                            ier[6:0] <= ier[6:0] | data_in[6:0];
                        else
                            ier[6:0] <= ier[6:0] & ~data_in[6:0];
                    end
                    default: ;
                endcase
                
                // Special registers
                if (addr[10:0] == REG_CONFIG)
                    config_reg <= data_in;
                if (addr[10:0] == REG_VIDEO)
                    video_config <= data_in;
            end else begin
                case (addr[10:8])
                    3'h0: data_out <= port_b;
                    3'h4: data_out <= dir_b;
                    3'h6: data_out <= {1'b0, ifr[6:0]};
                    3'h7: data_out <= {1'b1, ier[6:0]};
                    default: data_out <= 8'hFF;
                endcase
                
                // Special registers
                if (addr[10:0] == REG_CONFIG) begin
                    // Return RAM size | 0x04 (bit 2 always set)
                    case (ram_config)
                        2'b00: data_out <= 8'h04;  // 128K
                        2'b01: data_out <= 8'h05;  // 512K
                        2'b10: data_out <= 8'h06;  // 1MB
                        2'b11: data_out <= 8'h07;  // 4MB
                    endcase
                end
                if (addr[10:0] == REG_VIDEO) begin
                    // Monitor ID in bits 5:3
                    data_out <= {2'b00, monitor_id, 3'b000};
                end
            end
        end
    end
end

endmodule