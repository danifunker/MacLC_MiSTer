/*
 * Apple CUDA (Cuda-Could've-Done-It-Right) Controller Implementation
 * Based on MAME's cuda.cpp by R. Belmont
 *
 * CUDA is a 68HC05E1/E5 microcontroller that handles:
 * - ADB (Apple Desktop Bus) - keyboard/mouse
 * - I2C communication (DFAC)
 * - Power management
 * - Parameter RAM (PRAM)
 * - Real-time clock
 *
 * This implementation emulates the CUDA's behavior as seen by the host Mac.
 * The actual 68HC05 firmware logic is simplified to functional responses.
 */

module cuda (
    input         clk,
    input         clk8_en,          // 8MHz clock enable
    input         reset,

    // VIA interface - Port B connections
    input   [7:0] via_pb_i,         // VIA Port B inputs
    output  [7:0] cuda_pb_o,        // CUDA Port B outputs
    output  [7:0] cuda_pb_oe,       // CUDA Port B output enables

    // VIA shift register interface
    input         via_sr_active,    // VIA shift register is active
    input         via_sr_out,       // VIA shift direction (1=out to CUDA)
    input   [7:0] via_sr_data_out,  // Data from VIA shift register
    output  [7:0] cuda_sr_data_in,  // Data to VIA shift register
    output        cuda_sr_trigger,  // Trigger VIA SR interrupt

    // CB1/CB2 for shift register handshake
    output        cuda_cb1,         // Clock signal
    output        cuda_cb1_oe,
    output        cuda_cb2,         // Data signal
    output        cuda_cb2_oe,

    // ADB interface (simplified)
    input         adb_data_in,
    output        adb_data_out,
    output        adb_data_oe,

    // I2C interface (DFAC)
    inout         iic_sda,
    inout         iic_scl,

    // System control outputs
    output        reset_out,        // 68k reset
    output        nmi_out,          // 68k NMI
    output        dfac_latch        // DFAC latch signal
);

    //==========================================================================
    // Port B bit assignments (from MAME cuda.cpp)
    //==========================================================================
    // Port B mapping:
    // bit 7: DFAC bit clock (IIC SCL)
    // bit 6: DFAC data I/O (IIC SDA)  
    // bit 5: VIA shift register data
    // bit 4: VIA clock
    // bit 3: VIA TIP
    // bit 2: VIA BYTEACK
    // bit 1: VIA TREQ (Transfer Request)
    // bit 0: +5V sense

    localparam PB_PLUS5V_SENSE = 0;
    localparam PB_TREQ         = 1;
    localparam PB_BYTEACK      = 2;
    localparam PB_TIP          = 3;
    localparam PB_VIA_CLK      = 4;
    localparam PB_VIA_DATA     = 5;
    localparam PB_IIC_SDA      = 6;
    localparam PB_IIC_SCL      = 7;

    //==========================================================================
    // CUDA Protocol States
    //==========================================================================
    localparam ST_IDLE         = 4'd0;
    localparam ST_RECEIVE_CMD  = 4'd1;
    localparam ST_RECV_LENGTH  = 4'd2;
    localparam ST_RECV_DATA    = 4'd3;
    localparam ST_PROCESS      = 4'd4;
    localparam ST_SEND_LENGTH  = 4'd5;
    localparam ST_SEND_DATA    = 4'd6;
    localparam ST_WAIT_DONE    = 4'd7;
    localparam ST_SHIFT_BYTE   = 4'd8;

    //==========================================================================
    // CUDA Command Codes (from Mac OS)
    //==========================================================================
    localparam CMD_AUTOPOLL       = 8'h01;
    localparam CMD_READ_PRAM      = 8'h07;
    localparam CMD_WRITE_PRAM     = 8'h0C;
    localparam CMD_READ_RTC       = 8'h03;
    localparam CMD_WRITE_RTC      = 8'h09;
    localparam CMD_READ_VERSION   = 8'h11;
    localparam CMD_ADB_COMMAND    = 8'h00;
    localparam CMD_PSEUDO         = 8'h02; // Pseudo command responses

    //==========================================================================
    // Internal State
    //==========================================================================
    reg [3:0]  state;
    reg [7:0]  command;
    reg [7:0]  length;
    reg [7:0]  data_count;
    reg [7:0]  response_length;
    reg [7:0]  response_count;
    
    // Packet buffers
    reg [7:0]  rx_buffer[0:15];
    reg [7:0]  tx_buffer[0:15];
    
    // VIA handshake signals
    reg        treq;                // Transfer request (1 = ready)
    reg        tip;                 // Transaction in progress
    reg        byteack;             // Byte acknowledge
    
    // Shift register state
    reg [3:0]  bit_count;
    reg [7:0]  shift_reg_in;
    reg [7:0]  shift_reg_out;
    reg [7:0]  clk_count;
    reg        cb1_reg;
    reg        cb1_oe_reg;
    reg        cb2_reg;
    reg        cb2_oe_reg;
    reg        sr_trigger_reg;
    
    // PRAM simulation (256 bytes)
    reg [7:0]  pram[0:255];
    
    // RTC (simplified - just seconds counter)
    reg [31:0] rtc_seconds;
    reg [23:0] rtc_counter;
    
    // ADB state
    reg        adb_out_reg;
    reg        adb_oe_reg;
    reg        autopoll_enabled;
    
    // Power/reset control
    reg        reset_line;
    reg        nmi_line;
    reg        dfac_latch_reg;
    
    // Previous state tracking
    reg        via_sr_active_prev;
    reg        via_sr_out_prev;

    //==========================================================================
    // Output Assignments
    //==========================================================================
    
    // Port B outputs
    assign cuda_pb_o[PB_PLUS5V_SENSE] = 1'b1;  // +5V present
    assign cuda_pb_o[PB_TREQ]         = ~treq; // Active low
    assign cuda_pb_o[PB_BYTEACK]      = byteack;
    assign cuda_pb_o[PB_TIP]          = tip;
    assign cuda_pb_o[PB_VIA_CLK]      = 1'b1;  // Default high
    assign cuda_pb_o[PB_VIA_DATA]     = 1'b1;  // Default high
    assign cuda_pb_o[PB_IIC_SDA]      = 1'b1;  // Pull-up
    assign cuda_pb_o[PB_IIC_SCL]      = 1'b1;  // Pull-up
    
    assign cuda_pb_oe = 8'b11111111;  // Drive all bits
    
    // Shift register interface
    assign cuda_sr_data_in = shift_reg_out;
    assign cuda_sr_trigger = sr_trigger_reg;
    
    // CB1/CB2 for external shift clock mode
    assign cuda_cb1    = cb1_reg;
    assign cuda_cb1_oe = cb1_oe_reg;
    assign cuda_cb2    = cb2_reg;
    assign cuda_cb2_oe = cb2_oe_reg;
    
    // ADB output
    assign adb_data_out = adb_out_reg;
    assign adb_data_oe  = adb_oe_reg;
    
    // System control
    assign reset_out   = reset_line;
    assign nmi_out     = nmi_line;
    assign dfac_latch  = dfac_latch_reg;

    //==========================================================================
    // RTC Counter - counts at ~1Hz
    //==========================================================================
    always @(posedge clk) begin
        if (reset) begin
            rtc_counter <= 24'd0;
            rtc_seconds <= 32'h0;
        end else if (clk8_en) begin
            if (rtc_counter >= 24'd8000000) begin  // ~1 second at 8MHz
                rtc_counter <= 24'd0;
                rtc_seconds <= rtc_seconds + 1'd1;
            end else begin
                rtc_counter <= rtc_counter + 1'd1;
            end
        end
    end

    //==========================================================================
    // Main CUDA State Machine
    //==========================================================================
    integer i;
    
    always @(posedge clk) begin
        if (reset) begin
            state <= ST_IDLE;
            treq <= 1'b1;
            tip <= 1'b0;
            byteack <= 1'b0;
            command <= 8'h00;
            length <= 8'h00;
            data_count <= 8'h00;
            response_length <= 8'h00;
            response_count <= 8'h00;
            bit_count <= 4'h0;
            clk_count <= 8'h0;
            shift_reg_in <= 8'h00;
            shift_reg_out <= 8'h00;
            cb1_reg <= 1'b1;
            cb1_oe_reg <= 1'b0;
            cb2_reg <= 1'b1;
            cb2_oe_reg <= 1'b0;
            sr_trigger_reg <= 1'b0;
            adb_out_reg <= 1'b1;
            adb_oe_reg <= 1'b0;
            autopoll_enabled <= 1'b0;
            reset_line <= 1'b0;
            nmi_line <= 1'b0;
            dfac_latch_reg <= 1'b0;
            via_sr_active_prev <= 1'b0;
            via_sr_out_prev <= 1'b0;
            
            // Initialize PRAM with defaults
            for (i = 0; i < 256; i = i + 1) begin
                pram[i] <= 8'h00;
            end
            
            // Set some default PRAM values
            pram[8'h08] <= 8'h13;  // Boot volume
            pram[8'h09] <= 8'h80;  // Startup disk
            
        end else if (clk8_en) begin
            via_sr_active_prev <= via_sr_active;
            via_sr_out_prev <= via_sr_out;
            sr_trigger_reg <= 1'b0;
            
            case (state)
                //--------------------------------------------------------------
                ST_IDLE: begin
                    treq <= 1'b1;           // Ready for transaction
                    tip <= 1'b0;            // No transaction active
                    byteack <= 1'b0;
                    cb1_oe_reg <= 1'b0;
                    cb2_oe_reg <= 1'b0;
                    bit_count <= 4'h0;
                    data_count <= 8'h00;
                    response_count <= 8'h00;
                    
                    // Detect start of transaction (TIP asserted by host)
                    if (via_pb_i[PB_TIP] && !tip) begin
                        tip <= 1'b1;
                        treq <= 1'b0;       // Not ready during transaction
                        state <= ST_RECEIVE_CMD;
                    end
                end
                
                //--------------------------------------------------------------
                ST_RECEIVE_CMD: begin
                    // Wait for VIA to start shift register
                    if (via_sr_active && via_sr_out && !via_sr_active_prev) begin
                        state <= ST_SHIFT_BYTE;
                        bit_count <= 4'h0;
                        cb1_oe_reg <= 1'b1;  // Drive clock
                        clk_count <= 8'h0;
                    end
                end
                
                //--------------------------------------------------------------
                ST_SHIFT_BYTE: begin
                    // Generate shift clock pulses
                    cb1_oe_reg <= 1'b1;
                    
                    clk_count <= clk_count + 1'd1;
                    
                    if (clk_count >= 8'd10) begin
                        clk_count <= 8'd0;
                        cb1_reg <= ~cb1_reg;
                        
                        if (cb1_reg) begin  // Rising edge
                            // Capture bit from VIA
                            shift_reg_in <= {shift_reg_in[6:0], via_pb_i[PB_VIA_DATA]};
                            bit_count <= bit_count + 1'd1;
                            
                            if (bit_count >= 4'd7) begin
                                // Byte complete
                                command <= shift_reg_in;
                                byteack <= 1'b1;
                                cb1_oe_reg <= 1'b0;
                                state <= ST_RECV_LENGTH;
                                clk_count <= 8'd0;
                            end
                        end
                    end
                end
                
                //--------------------------------------------------------------
                ST_RECV_LENGTH: begin
                    byteack <= 1'b0;
                    
                    // Wait for next byte (length)
                    if (via_sr_active && via_sr_out) begin
                        // Receive length byte similarly
                        length <= via_sr_data_out;
                        
                        if (length > 0) begin
                            state <= ST_RECV_DATA;
                            data_count <= 8'h00;
                        end else begin
                            state <= ST_PROCESS;
                        end
                    end
                end
                
                //--------------------------------------------------------------
                ST_RECV_DATA: begin
                    // Receive data bytes
                    if (via_sr_active && via_sr_out) begin
                        rx_buffer[data_count[3:0]] <= via_sr_data_out;
                        data_count <= data_count + 1'd1;
                        
                        if (data_count >= length - 1'd1) begin
                            state <= ST_PROCESS;
                        end
                    end
                end
                
                //--------------------------------------------------------------
                ST_PROCESS: begin
                    // Process command and prepare response
                    treq <= 1'b1;  // Signal ready to respond
                    
                    case (command)
                        CMD_READ_PRAM: begin
                            // Read PRAM: rx_buffer[0] = address
                            tx_buffer[0] <= CMD_PSEUDO;
                            tx_buffer[1] <= pram[rx_buffer[0]];
                            response_length <= 8'd2;
                            state <= ST_SEND_LENGTH;
                        end
                        
                        CMD_WRITE_PRAM: begin
                            // Write PRAM: rx_buffer[0] = address, rx_buffer[1] = data
                            pram[rx_buffer[0]] <= rx_buffer[1];
                            tx_buffer[0] <= CMD_PSEUDO;
                            response_length <= 8'd1;
                            state <= ST_SEND_LENGTH;
                        end
                        
                        CMD_READ_RTC: begin
                            // Return RTC value (4 bytes, little endian)
                            tx_buffer[0] <= CMD_PSEUDO;
                            tx_buffer[1] <= rtc_seconds[7:0];
                            tx_buffer[2] <= rtc_seconds[15:8];
                            tx_buffer[3] <= rtc_seconds[23:16];
                            tx_buffer[4] <= rtc_seconds[31:24];
                            response_length <= 8'd5;
                            state <= ST_SEND_LENGTH;
                        end
                        
                        CMD_WRITE_RTC: begin
                            // Set RTC (4 bytes received)
                            rtc_seconds <= {rx_buffer[3], rx_buffer[2], 
                                          rx_buffer[1], rx_buffer[0]};
                            tx_buffer[0] <= CMD_PSEUDO;
                            response_length <= 8'd1;
                            state <= ST_SEND_LENGTH;
                        end
                        
                        CMD_READ_VERSION: begin
                            // CUDA version 2.40 = 0x00020028
                            tx_buffer[0] <= CMD_PSEUDO;
                            tx_buffer[1] <= 8'h00;  // Version high
                            tx_buffer[2] <= 8'h02;
                            tx_buffer[3] <= 8'h00;
                            tx_buffer[4] <= 8'h28;  // Version low (2.40)
                            response_length <= 8'd5;
                            state <= ST_SEND_LENGTH;
                        end
                        
                        CMD_AUTOPOLL: begin
                            // Enable/disable autopoll
                            autopoll_enabled <= rx_buffer[0][0];
                            tx_buffer[0] <= CMD_PSEUDO;
                            response_length <= 8'd1;
                            state <= ST_SEND_LENGTH;
                        end
                        
                        CMD_ADB_COMMAND: begin
                            // ADB command - return empty response for now
                            tx_buffer[0] <= CMD_PSEUDO;
                            response_length <= 8'd1;
                            state <= ST_SEND_LENGTH;
                        end
                        
                        default: begin
                            // Unknown command - minimal response
                            tx_buffer[0] <= CMD_PSEUDO;
                            response_length <= 8'd1;
                            state <= ST_SEND_LENGTH;
                        end
                    endcase
                end
                
                //--------------------------------------------------------------
                ST_SEND_LENGTH: begin
                    // Wait for host to be ready for response
                    if (!via_pb_i[PB_TIP]) begin
                        // Send response length
                        shift_reg_out <= response_length;
                        response_count <= 8'h00;
                        state <= ST_SEND_DATA;
                        treq <= 1'b0;  // Indicate data ready
                    end
                end
                
                //--------------------------------------------------------------
                ST_SEND_DATA: begin
                    // Send response bytes
                    if (via_sr_active && !via_sr_out) begin  // VIA reading from CUDA
                        shift_reg_out <= tx_buffer[response_count[3:0]];
                        response_count <= response_count + 1'd1;
                        
                        if (response_count >= response_length - 1'd1) begin
                            state <= ST_WAIT_DONE;
                        end
                    end
                end
                
                //--------------------------------------------------------------
                ST_WAIT_DONE: begin
                    treq <= 1'b1;
                    clk_count <= clk_count + 1'd1;
                    if (clk_count >= 8'd50) begin
                        state <= ST_IDLE;
                    end
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
