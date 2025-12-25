/*
 * Apple CUDA for Mac LC/LC II Integration
 * Optimized for actual Mac ROM CUDA protocol
 *
 * This version is specifically tailored for use in the MiSTer Mac LC core,
 * with proper VIA shift register integration and protocol handling.
 */

module cuda_maclc (
    input         clk,
    input         clk8_en,
    input         reset,

    // Direct VIA Port B connections
    input         via_tip,          // VIA Port B bit 3 - Transaction In Progress
    input         via_byteack_in,   // VIA Port B bit 2 - from VIA (unused in most configs)
    output        cuda_treq,        // Port B bit 1 - Transfer Request (active LOW)
    output        cuda_byteack,     // Port B bit 2 - Byte Acknowledge
    
    // VIA Shift Register interface (CB1/CB2)
    output        cuda_cb1,         // CB1 - Shift clock (CUDA drives in external mode)
    input         via_cb2_in,       // CB2 - Data from VIA (when VIA sending)
    output        cuda_cb2,         // CB2 - Data to VIA (when CUDA sending)
    output        cuda_cb2_oe,      // CB2 output enable
    
    // VIA SR control signals
    input         via_sr_read,      // VIA is reading SR (shift in mode)
    input         via_sr_write,     // VIA has written SR (shift out mode)
    output reg    cuda_sr_irq,      // Request SR interrupt
    
    // Full port B for completeness
    output [7:0]  cuda_portb,       // Complete Port B output
    output [7:0]  cuda_portb_oe,    // Port B output enables
    
    // ADB signals (simplified)
    input         adb_data_in,
    output reg    adb_data_out,
    
    // System control
    output reg    reset_680x0,
    output reg    nmi_680x0
);

    //==========================================================================
    // Port B Bit Definitions
    //==========================================================================
    localparam PB_5V_SENSE  = 0;
    localparam PB_TREQ      = 1;
    localparam PB_BYTEACK   = 2;
    localparam PB_TIP       = 3;
    localparam PB_VIA_CLK   = 4;
    localparam PB_VIA_DATA  = 5;
    localparam PB_IIC_SDA   = 6;
    localparam PB_IIC_SCL   = 7;

    //==========================================================================
    // CUDA Protocol States
    //==========================================================================
    typedef enum logic [3:0] {
        IDLE,
        WAIT_CMD,
        SHIFT_IN_CMD,
        WAIT_LENGTH,
        SHIFT_IN_LENGTH,
        SHIFT_IN_DATA,
        PROCESS_CMD,
        PREPARE_RESPONSE,
        WAIT_TIP_FALL,
        SHIFT_OUT_LENGTH,
        SHIFT_OUT_DATA,
        COMPLETE
    } state_t;
    
    state_t state, next_state;

    //==========================================================================
    // CUDA Commands
    //==========================================================================
    localparam [7:0] CMD_ADB        = 8'h00;
    localparam [7:0] CMD_AUTOPOLL   = 8'h01;
    localparam [7:0] CMD_PSEUDO     = 8'h02;  // Response prefix
    localparam [7:0] CMD_READ_RTC   = 8'h03;
    localparam [7:0] CMD_READ_PRAM  = 8'h07;
    localparam [7:0] CMD_WRITE_RTC  = 8'h09;
    localparam [7:0] CMD_WRITE_PRAM = 8'h0C;
    localparam [7:0] CMD_VERSION    = 8'h11;
    localparam [7:0] CMD_SET_POWER  = 8'h13;

    //==========================================================================
    // Internal Registers
    //==========================================================================
    reg [7:0]  command_byte;
    reg [7:0]  length_byte;
    reg [7:0]  recv_data[0:7];      // Receive buffer
    reg [7:0]  send_data[0:7];      // Send buffer
    reg [3:0]  recv_count;
    reg [3:0]  send_count;
    reg [3:0]  send_length;
    
    // Shift register state
    reg [7:0]  shift_in;            // Incoming byte
    reg [7:0]  shift_out;           // Outgoing byte
    reg [3:0]  bit_counter;
    reg [7:0]  shift_clk_div;
    reg        cb1_out;
    reg        cb2_out_reg;
    reg        cb2_oe_reg;
    
    // PRAM storage
    reg [7:0]  pram[0:255];
    
    // RTC
    reg [31:0] rtc_seconds;
    reg [23:0] rtc_tick_counter;
    
    // Control signals
    reg        treq_reg;
    reg        byteack_reg;
    
    // Edge detection
    reg        via_tip_prev;
    reg        via_sr_write_prev;
    reg        via_sr_read_prev;

    //==========================================================================
    // Output Assignments
    //==========================================================================
    assign cuda_treq = treq_reg;
    assign cuda_byteack = byteack_reg;
    assign cuda_cb1 = cb1_out;
    assign cuda_cb2 = cb2_out_reg;
    assign cuda_cb2_oe = cb2_oe_reg;
    
    // Full Port B output
    assign cuda_portb[PB_5V_SENSE] = 1'b1;      // +5V present
    assign cuda_portb[PB_TREQ]     = treq_reg;
    assign cuda_portb[PB_BYTEACK]  = byteack_reg;
    assign cuda_portb[PB_TIP]      = 1'b0;      // Input only
    assign cuda_portb[PB_VIA_CLK]  = 1'b1;      // Unused
    assign cuda_portb[PB_VIA_DATA] = 1'b1;      // Unused  
    assign cuda_portb[PB_IIC_SDA]  = 1'b1;      // Pull-up
    assign cuda_portb[PB_IIC_SCL]  = 1'b1;      // Pull-up
    
    assign cuda_portb_oe = 8'b11110111;         // All except TIP

    //==========================================================================
    // RTC Counter
    //==========================================================================
    always @(posedge clk) begin
        if (reset) begin
            rtc_seconds <= 32'h0;
            rtc_tick_counter <= 24'h0;
        end else if (clk8_en) begin
            // Count to ~8MHz for 1 second
            if (rtc_tick_counter >= 24'd8_000_000) begin
                rtc_tick_counter <= 24'h0;
                rtc_seconds <= rtc_seconds + 1'd1;
            end else begin
                rtc_tick_counter <= rtc_tick_counter + 1'd1;
            end
        end
    end

    //==========================================================================
    // Main State Machine
    //==========================================================================
    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            via_tip_prev <= 1'b0;
            via_sr_write_prev <= 1'b0;
            via_sr_read_prev <= 1'b0;
        end else if (clk8_en) begin
            state <= next_state;
            via_tip_prev <= via_tip;
            via_sr_write_prev <= via_sr_write;
            via_sr_read_prev <= via_sr_read;
        end
    end
    
    // Next state logic
    always @(*) begin
        next_state = state;
        
        case (state)
            IDLE: begin
                // Wait for TIP to be asserted (rising edge)
                if (via_tip && !via_tip_prev)
                    next_state = WAIT_CMD;
            end
            
            WAIT_CMD: begin
                // Wait for VIA to write command byte
                if (via_sr_write && !via_sr_write_prev)
                    next_state = SHIFT_IN_CMD;
            end
            
            SHIFT_IN_CMD: begin
                if (bit_counter >= 4'd8)
                    next_state = WAIT_LENGTH;
            end
            
            WAIT_LENGTH: begin
                if (via_sr_write && !via_sr_write_prev)
                    next_state = SHIFT_IN_LENGTH;
            end
            
            SHIFT_IN_LENGTH: begin
                if (bit_counter >= 4'd8) begin
                    if (length_byte > 0)
                        next_state = SHIFT_IN_DATA;
                    else
                        next_state = PROCESS_CMD;
                end
            end
            
            SHIFT_IN_DATA: begin
                if (recv_count >= length_byte)
                    next_state = PROCESS_CMD;
            end
            
            PROCESS_CMD: begin
                next_state = PREPARE_RESPONSE;
            end
            
            PREPARE_RESPONSE: begin
                next_state = WAIT_TIP_FALL;
            end
            
            WAIT_TIP_FALL: begin
                // Wait for TIP to fall (host ready to receive)
                if (!via_tip && via_tip_prev)
                    next_state = SHIFT_OUT_LENGTH;
            end
            
            SHIFT_OUT_LENGTH: begin
                if (bit_counter >= 4'd8)
                    next_state = SHIFT_OUT_DATA;
            end
            
            SHIFT_OUT_DATA: begin
                if (send_count >= send_length)
                    next_state = COMPLETE;
            end
            
            COMPLETE: begin
                next_state = IDLE;
            end
        endcase
    end
    
    //==========================================================================
    // State Machine Outputs
    //==========================================================================
    integer i;
    
    always @(posedge clk) begin
        if (reset) begin
            treq_reg <= 1'b1;           // Ready (active low on wire)
            byteack_reg <= 1'b0;
            cb1_out <= 1'b1;
            cb2_out_reg <= 1'b1;
            cb2_oe_reg <= 1'b0;
            cuda_sr_irq <= 1'b0;
            command_byte <= 8'h00;
            length_byte <= 8'h00;
            recv_count <= 4'h0;
            send_count <= 4'h0;
            send_length <= 4'h0;
            bit_counter <= 4'h0;
            shift_clk_div <= 8'h0;
            shift_in <= 8'h00;
            shift_out <= 8'h00;
            reset_680x0 <= 1'b0;
            nmi_680x0 <= 1'b0;
            adb_data_out <= 1'b1;
            
            // Initialize PRAM
            for (i = 0; i < 256; i = i + 1)
                pram[i] <= 8'h00;
            pram[8'h08] <= 8'h13;       // Boot drive
            
        end else if (clk8_en) begin
            cuda_sr_irq <= 1'b0;        // Pulse
            
            case (state)
                IDLE: begin
                    treq_reg <= 1'b1;       // Ready
                    byteack_reg <= 1'b0;
                    cb2_oe_reg <= 1'b0;     // Not driving CB2
                    bit_counter <= 4'h0;
                    recv_count <= 4'h0;
                    send_count <= 4'h0;
                end
                
                WAIT_CMD, WAIT_LENGTH: begin
                    treq_reg <= 1'b0;       // Busy
                    byteack_reg <= 1'b0;
                end
                
                SHIFT_IN_CMD, SHIFT_IN_LENGTH, SHIFT_IN_DATA: begin
                    // Clock in byte from VIA
                    shift_clk_div <= shift_clk_div + 1'd1;
                    
                    // Generate slower shift clock
                    if (shift_clk_div >= 8'd16) begin
                        shift_clk_div <= 8'h0;
                        cb1_out <= ~cb1_out;
                        
                        if (cb1_out) begin  // Sample on high-to-low
                            shift_in <= {shift_in[6:0], via_cb2_in};
                            bit_counter <= bit_counter + 1'd1;
                            
                            if (bit_counter == 4'd7) begin
                                // Byte complete
                                if (state == SHIFT_IN_CMD) begin
                                    command_byte <= {shift_in[6:0], via_cb2_in};
                                end else if (state == SHIFT_IN_LENGTH) begin
                                    length_byte <= {shift_in[6:0], via_cb2_in};
                                end else begin
                                    recv_data[recv_count[2:0]] <= {shift_in[6:0], via_cb2_in};
                                    recv_count <= recv_count + 1'd1;
                                end
                                
                                byteack_reg <= 1'b1;
                                cuda_sr_irq <= 1'b1;
                                bit_counter <= 4'h0;
                            end
                        end
                    end
                end
                
                PROCESS_CMD: begin
                    // Process command and prepare response
                    byteack_reg <= 1'b0;
                    
                    case (command_byte)
                        CMD_READ_PRAM: begin
                            send_data[0] <= CMD_PSEUDO;
                            send_data[1] <= pram[recv_data[0]];
                            send_length <= 4'd2;
                        end
                        
                        CMD_WRITE_PRAM: begin
                            pram[recv_data[0]] <= recv_data[1];
                            send_data[0] <= CMD_PSEUDO;
                            send_length <= 4'd1;
                        end
                        
                        CMD_READ_RTC: begin
                            send_data[0] <= CMD_PSEUDO;
                            send_data[1] <= rtc_seconds[7:0];
                            send_data[2] <= rtc_seconds[15:8];
                            send_data[3] <= rtc_seconds[23:16];
                            send_data[4] <= rtc_seconds[31:24];
                            send_length <= 4'd5;
                        end
                        
                        CMD_WRITE_RTC: begin
                            rtc_seconds <= {recv_data[3], recv_data[2],
                                          recv_data[1], recv_data[0]};
                            send_data[0] <= CMD_PSEUDO;
                            send_length <= 4'd1;
                        end
                        
                        CMD_VERSION: begin
                            send_data[0] <= CMD_PSEUDO;
                            send_data[1] <= 8'h00;      // Version 2.40
                            send_data[2] <= 8'h02;
                            send_data[3] <= 8'h00;
                            send_data[4] <= 8'h28;
                            send_length <= 4'd5;
                        end
                        
                        default: begin
                            send_data[0] <= CMD_PSEUDO;
                            send_length <= 4'd1;
                        end
                    endcase
                end
                
                PREPARE_RESPONSE: begin
                    treq_reg <= 1'b1;       // Signal response ready (goes low on wire)
                    send_count <= 4'h0;
                    bit_counter <= 4'h0;
                end
                
                SHIFT_OUT_LENGTH, SHIFT_OUT_DATA: begin
                    cb2_oe_reg <= 1'b1;     // Drive CB2
                    shift_clk_div <= shift_clk_div + 1'd1;
                    
                    if (shift_clk_div >= 8'd16) begin
                        shift_clk_div <= 8'h0;
                        cb1_out <= ~cb1_out;
                        
                        if (!cb1_out) begin  // Output on low-to-high
                            if (bit_counter == 4'h0) begin
                                // Load new byte
                                if (state == SHIFT_OUT_LENGTH)
                                    shift_out <= send_length;
                                else
                                    shift_out <= send_data[send_count[2:0]];
                            end
                            
                            cb2_out_reg <= shift_out[7];
                            shift_out <= {shift_out[6:0], 1'b0};
                            bit_counter <= bit_counter + 1'd1;
                            
                            if (bit_counter == 4'd7) begin
                                bit_counter <= 4'h0;
                                if (state == SHIFT_OUT_DATA) begin
                                    send_count <= send_count + 1'd1;
                                end
                                cuda_sr_irq <= 1'b1;
                            end
                        end
                    end
                end
                
                COMPLETE: begin
                    cb2_oe_reg <= 1'b0;
                end
            endcase
        end
    end

endmodule
