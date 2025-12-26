/*
 * Apple CUDA for Mac LC/LC II Integration
 * Optimized for actual Mac ROM CUDA protocol
 *
 * This version is specifically tailored for use in the MiSTer Mac LC core,
 * with proper VIA shift register integration and protocol handling.
 *
 * Based on MAME's cuda.cpp by R. Belmont
 */

module cuda_maclc (
    input         clk,
    input         clk8_en,
    input         reset,

    // RTC timestamp initialization (Unix time)
    input  [32:0] timestamp,

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
    localparam [3:0] ST_ATTENTION       = 4'd0;   // Startup: assert TREQ briefly
    localparam [3:0] ST_IDLE            = 4'd1;
    localparam [3:0] ST_WAIT_CMD        = 4'd2;
    localparam [3:0] ST_SHIFT_IN_CMD    = 4'd3;
    localparam [3:0] ST_WAIT_LENGTH     = 4'd4;
    localparam [3:0] ST_SHIFT_IN_LENGTH = 4'd5;
    localparam [3:0] ST_SHIFT_IN_DATA   = 4'd6;
    localparam [3:0] ST_PROCESS_CMD     = 4'd7;
    localparam [3:0] ST_PREPARE_RESPONSE= 4'd8;
    localparam [3:0] ST_WAIT_SR_READ    = 4'd9;   // Wait for ROM to read VIA SR
    localparam [3:0] ST_SHIFT_OUT_LENGTH= 4'd10;
    localparam [3:0] ST_SHIFT_OUT_DATA  = 4'd11;
    localparam [3:0] ST_COMPLETE        = 4'd12;
    localparam [3:0] ST_WAIT_TIP_RISE   = 4'd13;

    reg [3:0] state, next_state;

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
    reg        byte_complete;       // Pulses when a byte has been shifted

    // PRAM storage (256 bytes)
    reg [7:0]  pram[0:255];

    // RTC - Mac epoch is Jan 1, 1904 (differs from Unix epoch by 2082844800 seconds)
    // We store in Mac format for compatibility
    localparam [31:0] MAC_UNIX_DELTA = 32'd2082844800;
    reg [31:0] rtc_seconds;
    reg [23:0] rtc_tick_counter;
    reg        rtc_initialized;

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

    // TREQ (bit 1) handled via separate cuda_treq signal in dataController
    // TIP (bit 3) is input from VIA
    assign cuda_portb_oe = 8'b11110101;         // All except TIP and TREQ

    //==========================================================================
    // PRAM Default Initialization
    // These values are read by the Mac ROM during boot
    //==========================================================================
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            pram[i] = 8'h00;

        // Boot configuration
        pram[8'h08] = 8'h00;       // Boot device (internal HD)
        pram[8'h09] = 8'h08;       // Default video mode settings
        pram[8'h0A] = 8'h00;
        pram[8'h0B] = 8'h00;

        // Monitor config / video mode (important for palette init!)
        // Bits 2:0 = color depth: 0=1bpp, 1=2bpp, 2=4bpp, 3=8bpp
        pram[8'h10] = 8'h02;       // 4bpp mode
        pram[8'h11] = 8'h00;

        // Sound volume
        pram[8'h78] = 8'h07;       // Max volume

        // Valid PRAM signature
        pram[8'h7C] = 8'hA8;
        pram[8'h7D] = 8'h00;
        pram[8'h7E] = 8'h00;
        pram[8'h7F] = 8'h01;
    end

    //==========================================================================
    // RTC Counter with timestamp initialization
    //==========================================================================
    always @(posedge clk) begin
        if (reset) begin
            rtc_seconds <= 32'h0;
            rtc_tick_counter <= 24'h0;
            rtc_initialized <= 1'b0;
        end else if (clk8_en) begin
            // Initialize RTC from timestamp on first cycle after reset
            if (!rtc_initialized && timestamp != 0) begin
                // Convert Unix timestamp to Mac timestamp
                rtc_seconds <= timestamp[31:0] + MAC_UNIX_DELTA;
                rtc_initialized <= 1'b1;
            end else begin
                // Count to ~8MHz for 1 second
                if (rtc_tick_counter >= 24'd7_999_999) begin
                    rtc_tick_counter <= 24'h0;
                    rtc_seconds <= rtc_seconds + 1'd1;
                end else begin
                    rtc_tick_counter <= rtc_tick_counter + 1'd1;
                end
            end
        end
    end

    //==========================================================================
    // Main State Machine
    //==========================================================================
    // Debug counter to limit output
    reg [31:0] debug_cycle;
    reg [3:0] prev_state;

    always @(posedge clk) begin
        if (reset) begin
            state <= ST_ATTENTION;  // Start with attention signal
            via_tip_prev <= 1'b1;   // Start high (no transaction) to avoid false trigger
            via_sr_write_prev <= 1'b0;
            via_sr_read_prev <= 1'b0;
            debug_cycle <= 0;
            prev_state <= ST_ATTENTION;
        end else if (clk8_en) begin
            debug_cycle <= debug_cycle + 1;
            prev_state <= state;
            state <= next_state;
            via_tip_prev <= via_tip;
            via_sr_write_prev <= via_sr_write;
            via_sr_read_prev <= via_sr_read;

            // Debug: print state changes (reduced output)
            /* verilator lint_off STMTDLY */
            if (state != prev_state) begin
                $display("CUDA: state %d -> %d, TIP=%b, TREQ=%b",
                         prev_state, state, via_tip, treq_reg);
            end
            /* verilator lint_on STMTDLY */
        end
    end

    // Next state logic
    always @(*) begin
        next_state = state;

        case (state)
            ST_ATTENTION: begin
                // Stay in attention state until ROM acknowledges with TIP
                // Wait for TIP to fall (ROM response to attention)
                if (!via_tip && via_tip_prev)
                    next_state = ST_WAIT_CMD;
                // No timeout - stay in attention until ROM responds
                // (Real CUDA stays in attention indefinitely until acknowledged)
            end

            ST_IDLE: begin
                // Wait for TIP to be asserted (TIP is active LOW, so wait for falling edge)
                if (!via_tip && via_tip_prev)
                    next_state = ST_WAIT_CMD;
            end

            ST_WAIT_CMD: begin
                // Wait for VIA to write command byte
                if (via_sr_write && !via_sr_write_prev)
                    next_state = ST_SHIFT_IN_CMD;
            end

            ST_SHIFT_IN_CMD: begin
                if (byte_complete)
                    next_state = ST_WAIT_LENGTH;
            end

            ST_WAIT_LENGTH: begin
                if (via_sr_write && !via_sr_write_prev)
                    next_state = ST_SHIFT_IN_LENGTH;
            end

            ST_SHIFT_IN_LENGTH: begin
                if (byte_complete) begin
                    if (length_byte > 0)
                        next_state = ST_SHIFT_IN_DATA;
                    else
                        next_state = ST_PROCESS_CMD;
                end
            end

            ST_SHIFT_IN_DATA: begin
                if (recv_count >= length_byte)
                    next_state = ST_PROCESS_CMD;
            end

            ST_PROCESS_CMD: begin
                next_state = ST_PREPARE_RESPONSE;
            end

            ST_PREPARE_RESPONSE: begin
                // After preparing response, wait for ROM to read VIA SR
                // This signals that the VIA is ready to receive clocked data
                next_state = ST_WAIT_SR_READ;
            end

            ST_WAIT_SR_READ: begin
                // Wait for ROM to read VIA SR register
                // This triggers the VIA to be ready for external clock shift-in
                if (via_sr_read && !via_sr_read_prev) begin
                    // ROM has read SR, start clocking out next byte
                    if (send_count == 0)
                        next_state = ST_SHIFT_OUT_LENGTH;  // First byte is length
                    else if (send_count <= send_length)
                        next_state = ST_SHIFT_OUT_DATA;    // Data bytes
                    else
                        next_state = ST_COMPLETE;          // All done
                end
            end

            ST_SHIFT_OUT_LENGTH: begin
                if (byte_complete) begin
                    // After length byte, wait for next SR read
                    next_state = ST_WAIT_SR_READ;
                end
            end

            ST_SHIFT_OUT_DATA: begin
                if (byte_complete) begin
                    if (send_count >= send_length)
                        next_state = ST_COMPLETE;          // All bytes sent
                    else
                        next_state = ST_WAIT_SR_READ;      // Wait for next SR read
                end
            end

            ST_COMPLETE: begin
                // After sending all response bytes, wait for TIP to be released
                next_state = ST_WAIT_TIP_RISE;
            end

            ST_WAIT_TIP_RISE: begin
                // Wait for TIP to be released (TIP goes HIGH) to end the transaction
                if (via_tip && !via_tip_prev)
                    next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    //==========================================================================
    // State Machine Outputs and Data Processing
    //==========================================================================
    reg [15:0] attention_timer;  // Timer for startup attention signal

    always @(posedge clk) begin
        if (reset) begin
            treq_reg <= 1'b1;           // Assert TREQ at startup (attention)
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
            byte_complete <= 1'b0;
            reset_680x0 <= 1'b0;
            nmi_680x0 <= 1'b0;
            adb_data_out <= 1'b1;
            attention_timer <= 16'd0;

        end else if (clk8_en) begin
            cuda_sr_irq <= 1'b0;        // Pulse
            byte_complete <= 1'b0;      // Pulse

            case (state)
                ST_ATTENTION: begin
                    // Assert TREQ briefly at startup to signal CUDA presence
                    treq_reg <= 1'b1;       // Asserted (TREQ pin LOW)
                    byteack_reg <= 1'b0;
                    attention_timer <= attention_timer + 1'd1;
                end

                ST_IDLE: begin
                    treq_reg <= 1'b0;       // De-asserted (TREQ pin HIGH) in idle
                    byteack_reg <= 1'b0;
                    cb2_oe_reg <= 1'b0;     // Not driving CB2
                    bit_counter <= 4'h0;
                    recv_count <= 4'h0;
                    send_count <= 4'h0;
                end

                ST_WAIT_CMD, ST_WAIT_LENGTH: begin
                    treq_reg <= 1'b1;       // Asserted (TREQ pin LOW) to acknowledge TIP
                    byteack_reg <= 1'b0;
                end

                ST_SHIFT_IN_CMD, ST_SHIFT_IN_LENGTH, ST_SHIFT_IN_DATA: begin
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
                                if (state == ST_SHIFT_IN_CMD) begin
                                    command_byte <= {shift_in[6:0], via_cb2_in};
                                end else if (state == ST_SHIFT_IN_LENGTH) begin
                                    length_byte <= {shift_in[6:0], via_cb2_in};
                                end else begin
                                    recv_data[recv_count[2:0]] <= {shift_in[6:0], via_cb2_in};
                                    recv_count <= recv_count + 1'd1;
                                end

                                byteack_reg <= 1'b1;
                                cuda_sr_irq <= 1'b1;
                                byte_complete <= 1'b1;
                                bit_counter <= 4'h0;
                            end
                        end
                    end
                end

                ST_PROCESS_CMD: begin
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
                            // Return version 2.40 (0x00020028)
                            send_data[0] <= CMD_PSEUDO;
                            send_data[1] <= 8'h00;
                            send_data[2] <= 8'h02;
                            send_data[3] <= 8'h00;
                            send_data[4] <= 8'h28;
                            send_length <= 4'd5;
                        end

                        CMD_AUTOPOLL: begin
                            // Acknowledge autopoll setting
                            send_data[0] <= CMD_PSEUDO;
                            send_length <= 4'd1;
                        end

                        CMD_SET_POWER: begin
                            // Acknowledge power setting
                            send_data[0] <= CMD_PSEUDO;
                            send_length <= 4'd1;
                        end

                        default: begin
                            // Unknown command - just acknowledge
                            send_data[0] <= CMD_PSEUDO;
                            send_length <= 4'd1;
                        end
                    endcase
                end

                ST_PREPARE_RESPONSE: begin
                    treq_reg <= 1'b1;       // Signal response ready (TREQ goes LOW on wire)
                    send_count <= 4'h0;
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: PREPARE_RESPONSE - asserting TREQ, will send %d bytes",
                             send_length);
                    $display("CUDA: Response data[0]=0x%02x, data[1]=0x%02x",
                             send_data[0], send_data[1]);
                    /* verilator lint_on STMTDLY */
                end

                ST_WAIT_SR_READ: begin
                    // Waiting for ROM to read VIA SR
                    // Reset shift state for next byte
                    bit_counter <= 4'h0;
                    shift_clk_div <= 8'h0;
                    cb1_out <= 1'b1;        // Start with CB1 high
                    cb2_oe_reg <= 1'b0;     // Not driving CB2 yet

                    // When ROM reads SR, prepare the byte to send
                    if (via_sr_read && !via_sr_read_prev) begin
                        if (send_count == 0) begin
                            // First byte is the length
                            shift_out <= {4'h0, send_length};
                            cb2_out_reg <= 1'b0;  // MSB of length (always 0 since length < 16)
                            /* verilator lint_off STMTDLY */
                            $display("CUDA: SR read - sending LENGTH byte 0x%02x", {4'h0, send_length});
                            /* verilator lint_on STMTDLY */
                        end else begin
                            // Data bytes
                            shift_out <= send_data[send_count[2:0] - 1];
                            cb2_out_reg <= send_data[send_count[2:0] - 1][7];
                            /* verilator lint_off STMTDLY */
                            $display("CUDA: SR read - sending DATA[%d] = 0x%02x",
                                     send_count - 1, send_data[send_count[2:0] - 1]);
                            /* verilator lint_on STMTDLY */
                        end
                    end
                end

                ST_SHIFT_OUT_LENGTH, ST_SHIFT_OUT_DATA: begin
                    cb2_oe_reg <= 1'b1;     // Drive CB2
                    shift_clk_div <= shift_clk_div + 1'd1;

                    if (shift_clk_div >= 8'd16) begin
                        shift_clk_div <= 8'h0;
                        cb1_out <= ~cb1_out;

                        // CRITICAL TIMING FIX:
                        // - CB2 data must be stable BEFORE CB1 rising edge
                        // - VIA samples CB2 on CB1 rising edge
                        // - So CUDA outputs new CB2 data on CB1 FALLING edge
                        if (cb1_out) begin  // CB1 falling edge (cb1_out was 1, now goes to 0)
                            // Output current bit on CB2 - must happen BEFORE next rising edge
                            cb2_out_reg <= shift_out[7];

                            /* verilator lint_off STMTDLY */
                            $display("CUDA: CB1 FALL - bit %d, CB2=%b, shift_out=0x%02x, state=%d",
                                     bit_counter, shift_out[7], shift_out, state);
                            /* verilator lint_on STMTDLY */

                            // After outputting, shift to prepare next bit
                            shift_out <= {shift_out[6:0], 1'b0};
                            bit_counter <= bit_counter + 1'd1;

                            if (bit_counter == 4'd7) begin
                                // Byte complete
                                bit_counter <= 4'h0;
                                byte_complete <= 1'b1;
                                cuda_sr_irq <= 1'b1;

                                // Increment send_count to track progress
                                // send_count = 1 means length sent, now sending data[0]
                                // send_count = 2 means data[0] sent, now sending data[1]
                                // etc.
                                send_count <= send_count + 1'd1;

                                /* verilator lint_off STMTDLY */
                                $display("CUDA: BYTE COMPLETE in state %d, send_count %d -> %d, send_length=%d",
                                         state, send_count, send_count + 1, send_length);
                                /* verilator lint_on STMTDLY */
                            end
                        end else begin
                            // On CB1 rising edge: VIA samples CB2
                            /* verilator lint_off STMTDLY */
                            $display("CUDA: CB1 RISE - VIA should sample CB2=%b now", cb2_out_reg);
                            /* verilator lint_on STMTDLY */
                        end
                    end
                end

                ST_COMPLETE: begin
                    cb2_oe_reg <= 1'b0;
                end
            endcase
        end
    end

endmodule
