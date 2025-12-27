/*
 * Apple CUDA for Mac LC/LC II Integration
 * Fixed packet format: [packet_type][command][data...] - NO length byte!
 *
 * Packet types:
 *   0x00 = ADB_PACKET
 *   0x01 = CUDA_PACKET (pseudo commands)
 *   0x02 = ERROR_PACKET (responses)
 *   0x03 = TIMER_PACKET
 *
 * Based on MAME's cuda.cpp and Linux via-cuda.c
 */

module cuda_maclc (
    input         clk,
    input         clk8_en,
    input         reset,

    // RTC timestamp initialization (Unix time)
    input  [32:0] timestamp,

    // Direct VIA Port B connections
    input         via_tip,          // VIA Port B bit 5 - Transaction In Progress
    input         via_byteack_in,   // VIA Port B bit 4 - from VIA
    output        cuda_treq,        // Port B bit 3 - Transfer Request (active LOW)
    output        cuda_byteack,     // Port B bit 4 - Byte Acknowledge

    // VIA Shift Register interface (CB1/CB2)
    output        cuda_cb1,         // CB1 - Shift clock (CUDA drives in external mode)
    input         via_cb2_in,       // CB2 - Data from VIA (when VIA sending)
    output        cuda_cb2,         // CB2 - Data to VIA (when CUDA sending)
    output        cuda_cb2_oe,      // CB2 output enable

    // VIA SR control signals
    input         via_sr_read,      // VIA is reading SR (shift in mode)
    input         via_sr_write,     // VIA has written SR (shift out mode)
    input         via_sr_ext_clk,   // VIA is in external clock mode (ACR bits 4:2 = 11x)
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
    // Packet Type Definitions (from Linux uapi/linux/adb.h)
    //==========================================================================
    localparam [7:0] PKT_ADB        = 8'h00;
    localparam [7:0] PKT_CUDA       = 8'h01;
    localparam [7:0] PKT_ERROR      = 8'h02;
    localparam [7:0] PKT_TIMER      = 8'h03;

    //==========================================================================
    // CUDA Command Codes (from Linux uapi/linux/cuda.h)
    //==========================================================================
    localparam [7:0] CUDA_WARM_START    = 8'h00;
    localparam [7:0] CUDA_AUTOPOLL      = 8'h01;
    localparam [7:0] CUDA_GET_6805_ADDR = 8'h02;
    localparam [7:0] CUDA_GET_TIME      = 8'h03;
    localparam [7:0] CUDA_GET_PRAM      = 8'h07;
    localparam [7:0] CUDA_SET_6805_ADDR = 8'h08;
    localparam [7:0] CUDA_SET_TIME      = 8'h09;
    localparam [7:0] CUDA_POWERDOWN     = 8'h0A;
    localparam [7:0] CUDA_POWERUP_TIME  = 8'h0B;
    localparam [7:0] CUDA_SET_PRAM      = 8'h0C;
    localparam [7:0] CUDA_MS_RESET      = 8'h0D;
    localparam [7:0] CUDA_SEND_DFAC     = 8'h0E;
    localparam [7:0] CUDA_RESET_SYSTEM  = 8'h11;
    localparam [7:0] CUDA_SET_IPL       = 8'h12;
    localparam [7:0] CUDA_SET_AUTO_RATE = 8'h14;
    localparam [7:0] CUDA_GET_AUTO_RATE = 8'h16;
    localparam [7:0] CUDA_SET_DEV_LIST  = 8'h19;
    localparam [7:0] CUDA_GET_DEV_LIST  = 8'h1A;
    localparam [7:0] CUDA_GET_SET_IIC   = 8'h22;

    //==========================================================================
    // Port B Bit Definitions (Mac LC V8 protocol)
    //==========================================================================
    localparam PB_TREQ      = 3;  // CUDA output - Transfer Request
    localparam PB_BYTEACK   = 4;  // VIA output to CUDA
    localparam PB_TIP       = 5;  // VIA output to CUDA - Transaction In Progress

    //==========================================================================
    // CUDA State Machine
    //==========================================================================
    localparam [3:0] ST_IDLE            = 4'd0;
    localparam [3:0] ST_ATTENTION       = 4'd1;   // Startup: assert TREQ
    localparam [3:0] ST_RECV_BYTE       = 4'd2;   // Receiving a byte
    localparam [3:0] ST_RECV_WAIT       = 4'd3;   // Wait for next byte or end
    localparam [3:0] ST_PROCESS         = 4'd4;   // Process received packet
    localparam [3:0] ST_SEND_WAIT       = 4'd5;   // Wait for SR read before sending
    localparam [3:0] ST_SEND_BYTE       = 4'd6;   // Sending a byte
    localparam [3:0] ST_SEND_DONE       = 4'd7;   // Byte sent, wait for next
    localparam [3:0] ST_FINISH          = 4'd8;   // Transaction complete

    reg [3:0] state, next_state;

    //==========================================================================
    // Internal Registers
    //==========================================================================
    reg [7:0]  recv_buf[0:15];    // Receive buffer
    reg [3:0]  recv_count;        // Bytes received
    reg [7:0]  send_buf[0:15];    // Send buffer
    reg [3:0]  send_count;        // Bytes sent
    reg [3:0]  send_length;       // Total bytes to send

    // Shift register state
    reg [7:0]  shift_reg;
    reg [3:0]  bit_counter;
    reg [7:0]  shift_clk_div;
    reg        cb1_out;
    reg        cb2_out_reg;
    reg        cb2_oe_reg;

    // Control signals
    reg        treq_reg;
    reg        byteack_reg;

    // Edge detection
    reg        via_tip_prev;
    reg        via_sr_write_prev;
    reg        via_sr_read_prev;

    // Timing
    reg [15:0] wait_counter;

    // SR write tracking - only clock after ROM writes SR
    reg        sr_write_seen;

    // PRAM storage (256 bytes)
    reg [7:0]  pram[0:255];

    // RTC
    localparam [31:0] MAC_UNIX_DELTA = 32'd2082844800;
    reg [31:0] rtc_seconds;
    reg [23:0] rtc_tick_counter;
    reg        rtc_initialized;

    // Autopoll state
    reg        autopoll_enabled;

    //==========================================================================
    // Output Assignments
    //==========================================================================
    assign cuda_treq = treq_reg;  // treq_reg=1 means asserted, dataController inverts for pin
    assign cuda_byteack = byteack_reg;
    assign cuda_cb1 = cb1_out;
    assign cuda_cb2 = cb2_out_reg;
    assign cuda_cb2_oe = cb2_oe_reg;

    assign cuda_portb[2:0] = 3'b111;
    assign cuda_portb[PB_TREQ] = treq_reg;
    assign cuda_portb[PB_BYTEACK] = 1'b0;  // Input
    assign cuda_portb[PB_TIP] = 1'b0;      // Input
    assign cuda_portb[7:6] = 2'b11;
    assign cuda_portb_oe = 8'b11000111;

    //==========================================================================
    // PRAM Default Initialization
    //==========================================================================
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            pram[i] = 8'h00;
        pram[8'h08] = 8'h00;
        pram[8'h09] = 8'h08;
        pram[8'h10] = 8'h02;  // 4bpp mode
        pram[8'h78] = 8'h07;  // Volume
        pram[8'h7C] = 8'hA8;  // PRAM signature
        pram[8'h7D] = 8'h00;
        pram[8'h7E] = 8'h00;
        pram[8'h7F] = 8'h01;
    end

    //==========================================================================
    // RTC Counter
    //==========================================================================
    always @(posedge clk) begin
        if (reset) begin
            rtc_seconds <= 32'h0;
            rtc_tick_counter <= 24'h0;
            rtc_initialized <= 1'b0;
        end else if (clk8_en) begin
            if (!rtc_initialized && timestamp != 0) begin
                rtc_seconds <= timestamp[31:0] + MAC_UNIX_DELTA;
                rtc_initialized <= 1'b1;
            end else begin
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
    reg [3:0] prev_state;

    always @(posedge clk) begin
        if (reset) begin
            state <= ST_ATTENTION;
            via_tip_prev <= 1'b1;
            via_sr_write_prev <= 1'b0;
            via_sr_read_prev <= 1'b0;
            prev_state <= ST_ATTENTION;
        end else if (clk8_en) begin
            prev_state <= state;
            state <= next_state;
            via_tip_prev <= via_tip;
            via_sr_write_prev <= via_sr_write;
            via_sr_read_prev <= via_sr_read;

            if (state != prev_state) begin
                /* verilator lint_off STMTDLY */
                $display("CUDA: state %d -> %d, TIP=%b, TREQ=%b, recv_cnt=%d, send_cnt=%d",
                         prev_state, state, via_tip, treq_reg, recv_count, send_count);
                /* verilator lint_on STMTDLY */
            end
        end
    end

    // Next state logic
    always @(*) begin
        next_state = state;

        case (state)
            ST_ATTENTION: begin
                // At startup with TREQ asserted, wait for ROM to acknowledge with TIP
                // When ROM asserts TIP, send startup response (PKT_ERROR = 0x02)
                if (!via_tip && via_tip_prev) begin
                    next_state = ST_SEND_WAIT;  // ROM acknowledged, send startup response
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: ST_ATTENTION->ST_SEND_WAIT: ROM acknowledged with TIP");
                    /* verilator lint_on STMTDLY */
                end
                else if (wait_counter >= 16'd100000)
                    next_state = ST_IDLE;  // Timeout - go to idle anyway
            end

            ST_IDLE: begin
                // Wait for TIP to start a transaction
                if (!via_tip && via_tip_prev)
                    next_state = ST_RECV_WAIT;
            end

            ST_RECV_WAIT: begin
                // Wait for SR write (ROM sending byte)
                // IMPORTANT: Only continue receiving if TIP is still asserted (low)
                // ROM releases TIP between bytes to check TREQ
                //
                // Use combinational sr_write_now to catch SR write in same cycle
                // (sr_write_seen uses non-blocking assignment, not visible until next cycle)
                if (!via_tip && via_sr_write && !via_sr_write_prev) begin
                    // TIP asserted and new SR write - receive next byte
                    next_state = ST_RECV_BYTE;
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: RECV_WAIT->RECV_BYTE: sr_write edge, TIP=%b", via_tip);
                    /* verilator lint_on STMTDLY */
                end
                else if (recv_count > 0 && !sr_write_seen && !(via_sr_write && !via_sr_write_prev) && via_tip && wait_counter >= 16'd1000) begin
                    // TIP released, have data, no pending SR write, no SR write this cycle
                    next_state = ST_PROCESS;
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: RECV_WAIT->PROCESS: TIP released, recv_count=%d", recv_count);
                    /* verilator lint_on STMTDLY */
                end
                else if (recv_count == 0 && !sr_write_seen && !(via_sr_write && !via_sr_write_prev) && via_tip && wait_counter >= 16'd1000) begin
                    // TIP released with no data AND no pending SR write - go back to idle
                    next_state = ST_IDLE;
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: RECV_WAIT->IDLE: TIP released with no data");
                    /* verilator lint_on STMTDLY */
                end
                else if (recv_count > 0 && !sr_write_seen && !(via_sr_write && !via_sr_write_prev) && wait_counter >= 16'd50000) begin
                    // Timeout - process whatever we have (but not if pending SR write)
                    next_state = ST_PROCESS;
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: RECV_WAIT->PROCESS: timeout, recv_count=%d", recv_count);
                    /* verilator lint_on STMTDLY */
                end
                else if (recv_count > 0 && via_tip && wait_counter >= 16'd100000) begin
                    // Very long timeout - process even with pending SR write (byte was lost)
                    next_state = ST_PROCESS;
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: RECV_WAIT->PROCESS: long timeout, recv_count=%d, sr_write_seen=%b", recv_count, sr_write_seen);
                    /* verilator lint_on STMTDLY */
                end
            end

            ST_RECV_BYTE: begin
                // Shift in 8 bits
                if (bit_counter >= 4'd8)
                    next_state = ST_RECV_WAIT;
            end

            ST_PROCESS: begin
                // Process packet and prepare response
                next_state = ST_SEND_WAIT;
            end

            ST_SEND_WAIT: begin
                // CUDA sends to ROM:
                // - CUDA asserts TREQ to indicate it has data
                // - ROM asserts TIP to acknowledge
                // - ROM changes VIA to shift IN mode (writes ACR for external clock)
                // - ROM may read SR to clear any pending data
                // - CUDA clocks data on CB1/CB2
                //
                // IMPORTANT: Must wait for ROM to configure VIA before clocking!
                // ROM sequence: assert TIP -> write ACR (mode 7) -> poll IFR
                // We wait for via_sr_ext_clk (VIA is in external clock mode)
                if (send_count < send_length && !via_tip) begin
                    // TIP asserted by ROM - wait for VIA to enter external clock mode
                    if (via_sr_ext_clk) begin
                        next_state = ST_SEND_BYTE;
                        /* verilator lint_off STMTDLY */
                        $display("CUDA: SEND_WAIT->SEND_BYTE: sr_ext_clk=%b, wait=%d", via_sr_ext_clk, wait_counter);
                        /* verilator lint_on STMTDLY */
                    end
                end else if (send_count >= send_length) begin
                    next_state = ST_FINISH;
                end
                // Otherwise wait for TIP assertion and VIA external clock mode
            end

            ST_SEND_BYTE: begin
                // Shift out 8 bits - wait for final rising edge
                // bit_counter increments on falling edges, VIA samples on rising edges
                // So we're done when bit_counter=8 AND cb1 is high (after final rise)
                if (bit_counter >= 4'd8 && cb1_out) begin
                    next_state = ST_SEND_DONE;
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: ST_SEND_BYTE done - bit_counter=%d, cb1_out=%b", bit_counter, cb1_out);
                    /* verilator lint_on STMTDLY */
                end
            end

            ST_SEND_DONE: begin
                // Byte sent, wait for next SR read or TIP release
                if (via_tip)
                    next_state = ST_FINISH;
                else if (via_sr_read && !via_sr_read_prev) begin
                    if (send_count < send_length)
                        next_state = ST_SEND_BYTE;
                    else
                        next_state = ST_FINISH;
                end
            end

            ST_FINISH: begin
                // Wait for TIP to fully release
                if (via_tip && wait_counter >= 16'd10)
                    next_state = ST_IDLE;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    //==========================================================================
    // State Machine Outputs and Data Processing
    //==========================================================================
    always @(posedge clk) begin
        if (reset) begin
            treq_reg <= 1'b1;           // Assert TREQ at startup to signal CUDA presence
            byteack_reg <= 1'b0;
            cb1_out <= 1'b1;
            cb2_out_reg <= 1'b1;
            cb2_oe_reg <= 1'b0;
            cuda_sr_irq <= 1'b0;
            recv_count <= 4'h0;
            send_count <= 4'h0;
            send_length <= 4'h0;
            bit_counter <= 4'h0;
            shift_clk_div <= 8'h0;
            shift_reg <= 8'h00;
            wait_counter <= 16'h0;
            reset_680x0 <= 1'b0;
            nmi_680x0 <= 1'b0;
            adb_data_out <= 1'b1;
            autopoll_enabled <= 1'b0;
            sr_write_seen <= 1'b0;

        end else if (clk8_en) begin
            cuda_sr_irq <= 1'b0;

            // Track SR write events for clocking control
            if (via_sr_write && !via_sr_write_prev)
                sr_write_seen <= 1'b1;

            case (state)
                ST_ATTENTION: begin
                    byteack_reg <= 1'b0;
                    recv_count <= 4'h0;
                    treq_reg <= 1'b1;  // Assert TREQ at startup to signal CUDA presence
                    wait_counter <= wait_counter + 1'd1;

                    // When ROM asserts TIP (falling edge), prepare startup response
                    if (!via_tip && via_tip_prev) begin
                        // Prepare PKT_ERROR response for startup
                        send_buf[0] <= PKT_ERROR;  // 0x02
                        send_length <= 4'd1;
                        send_count <= 4'd0;
                        bit_counter <= 4'd0;
                        shift_reg <= PKT_ERROR;
                        cb2_out_reg <= PKT_ERROR[7];  // MSB first
                        cb2_oe_reg <= 1'b1;  // Enable CB2 output for sending
`ifdef SIMULATION
                        $display("CUDA: Preparing startup response PKT_ERROR (0x02)");
`endif
                    end else begin
                        send_count <= 4'h0;
                    end
`ifdef SIMULATION
                    if (wait_counter == 16'd0)
                        $display("CUDA: ST_ATTENTION starting, TREQ asserted, waiting for ROM TIP=%b", via_tip);
`endif
                end

                ST_IDLE: begin
                    treq_reg <= 1'b0;       // De-assert TREQ when idle
                    byteack_reg <= 1'b0;
                    cb2_oe_reg <= 1'b0;
                    bit_counter <= 4'h0;
                    recv_count <= 4'h0;
                    send_count <= 4'h0;
                    wait_counter <= 16'h0;
                    sr_write_seen <= 1'b0;  // Reset on idle
                    // Start cb1 low so first toggle on RECV_WAIT creates auto-trigger rising edge
                    cb1_out <= 1'b0;
                end

                ST_RECV_WAIT: begin
                    // CUDA must clock CB1 for VIA shift register (external clock mode)
                    // In mode 7 (external clock), CUDA provides CB1 clocks and VIA shifts data
                    // ROM sequence: TIP asserted -> ACR configured (mode 7) -> CUDA clocks -> IFR SR bit set
                    // Must wait for VIA to enter external clock mode before clocking
                    treq_reg <= 1'b0;
                    cb2_oe_reg <= 1'b0;
`ifdef SIMULATION
                    // Debug: trace when sr_write edge is detected
                    if (via_sr_write && !via_sr_write_prev) begin
                        $display("CUDA: RECV_WAIT sr_write EDGE! TIP=%b, sr_ext_clk=%b, bit_cnt=%d, cb1=%b",
                                 via_tip, via_sr_ext_clk, bit_counter, cb1_out);
                    end
`endif
                    // Only clock when TIP asserted AND VIA is in external clock mode
                    // AND we have seen an SR write (ROM has loaded data to shift)
                    // This prevents clocking before ROM has written data to SR
                    if (!via_tip && via_sr_ext_clk && sr_write_seen) begin
                        // TIP is asserted - provide CB1 clocks
                        // bit_counter < 8: clock and sample
                        // bit_counter == 8 && cb1_out == 0: need one more rising edge for VIA
                        // bit_counter == 8 && cb1_out == 1: done, wait for SR activity
                        // Need 9 rising edges total: 1 for VIA auto-trigger + 8 for 8-bit shift
                        // cb1_out starts low (set in ST_IDLE), first toggle creates auto-trigger rising edge
                        // bit_counter counts 8 falling edges (CUDA samples on these)
                        // Clock until bit_counter == 8 AND cb1_out is high (9th rising edge done)
                        if (bit_counter < 4'd8 || (bit_counter == 4'd8 && !cb1_out)) begin
                            // Still have bits to clock, or need final rising edge
                            shift_clk_div <= shift_clk_div + 1'd1;
                            // Clock slow enough for VIA to sample on E clock edges
                            if (shift_clk_div >= 8'd16) begin
                                shift_clk_div <= 8'h0;
                                cb1_out <= ~cb1_out;

                                if (cb1_out && bit_counter < 4'd8) begin  // Falling edge - sample CB2
                                    shift_reg <= {shift_reg[6:0], via_cb2_in};
                                    bit_counter <= bit_counter + 1'd1;

                                    if (bit_counter == 4'd7) begin
                                        // Byte complete
                                        // Only store if we saw an SR write (real data, not dummy)
                                        if (sr_write_seen) begin
                                            recv_buf[recv_count[3:0]] <= {shift_reg[6:0], via_cb2_in};
                                            recv_count <= recv_count + 1'd1;
                                            /* verilator lint_off STMTDLY */
                                            $display("CUDA: RECV_WAIT byte[%d] = 0x%02x", recv_count, {shift_reg[6:0], via_cb2_in});
                                            /* verilator lint_on STMTDLY */
                                        end else begin
                                            /* verilator lint_off STMTDLY */
                                            $display("CUDA: RECV_WAIT dummy byte (no SR write) = 0x%02x", {shift_reg[6:0], via_cb2_in});
                                            /* verilator lint_on STMTDLY */
                                        end
                                        sr_write_seen <= 1'b0;  // Wait for next SR write
                                    end
                                end
                            end
                        end else begin
                            // 8 bits done and CB1 high - wait for next SR write or activity
                            cb1_out <= 1'b1;
                            // Reset bit_counter when we see a new SR write
                            if (via_sr_write && !via_sr_write_prev) begin
                                bit_counter <= 4'h0;
                                shift_clk_div <= 8'h0;
`ifdef SIMULATION
                                $display("CUDA: RECV_WAIT sr_write edge detected, resetting bit_counter");
`endif
                            end
                        end
                    end else begin
                        // TIP is released - hold CB1 high
                        cb1_out <= 1'b1;
                        // Don't reset bit_counter here - ROM may bounce TIP between bytes
                    end

                    // Wait counter for detecting end of transaction
                    // Reset when TIP is asserted or on SR activity
                    // Increment when TIP is released (sustained inactivity detection)
                    if ((via_sr_write && !via_sr_write_prev) || (via_sr_read && !via_sr_read_prev) || !via_tip)
                        wait_counter <= 16'h0;
                    else if (via_tip)  // Count when TIP is released (any recv_count)
                        wait_counter <= wait_counter + 1'd1;
                end

                ST_RECV_BYTE: begin
                    // Reset bit_counter on entry (from RECV_WAIT)
                    if (prev_state == ST_RECV_WAIT) begin
                        bit_counter <= 4'h0;
                        shift_clk_div <= 8'h0;
                        cb1_out <= 1'b0;  // Start low for first rising edge
                    end else begin
                        // Clock in byte from VIA
                        shift_clk_div <= shift_clk_div + 1'd1;
                    end

                    // Clock slow enough for VIA to sample on E clock edges
                    if (prev_state != ST_RECV_WAIT && shift_clk_div >= 8'd16) begin
                        shift_clk_div <= 8'h0;
                        cb1_out <= ~cb1_out;

                        if (cb1_out) begin  // Falling edge - sample
                            shift_reg <= {shift_reg[6:0], via_cb2_in};
                            bit_counter <= bit_counter + 1'd1;

                            if (bit_counter == 4'd7) begin
                                // Byte complete - store it
                                recv_buf[recv_count[3:0]] <= {shift_reg[6:0], via_cb2_in};
                                recv_count <= recv_count + 1'd1;
                                /* verilator lint_off STMTDLY */
                                $display("CUDA: RECV byte[%d] = 0x%02x", recv_count, {shift_reg[6:0], via_cb2_in});
                                /* verilator lint_on STMTDLY */
                            end
                        end
                    end
                end

                ST_PROCESS: begin
                    // Process received packet
                    // Format: [packet_type][command][data...]
                    /* verilator lint_off STMTDLY */
                    $display("CUDA: PROCESS packet - type=0x%02x cmd=0x%02x data[0]=0x%02x cnt=%d",
                             recv_buf[0], recv_buf[1], recv_buf[2], recv_count);
                    /* verilator lint_on STMTDLY */

                    case (recv_buf[0])  // Packet type
                        PKT_CUDA: begin
                            // CUDA pseudo command
                            case (recv_buf[1])  // Command code
                                CUDA_AUTOPOLL: begin
                                    autopoll_enabled <= recv_buf[2][0];
                                    // Response: [ERROR_PKT] to acknowledge
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                    /* verilator lint_off STMTDLY */
                                    $display("CUDA: AUTOPOLL %s", recv_buf[2][0] ? "enabled" : "disabled");
                                    /* verilator lint_on STMTDLY */
                                end

                                CUDA_GET_TIME: begin
                                    // Response: [ERROR_PKT][time bytes...]
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= rtc_seconds[31:24];
                                    send_buf[2] <= rtc_seconds[23:16];
                                    send_buf[3] <= rtc_seconds[15:8];
                                    send_buf[4] <= rtc_seconds[7:0];
                                    send_length <= 4'd5;
                                end

                                CUDA_SET_TIME: begin
                                    rtc_seconds <= {recv_buf[2], recv_buf[3], recv_buf[4], recv_buf[5]};
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                end

                                CUDA_GET_PRAM: begin
                                    send_buf[0] <= PKT_ERROR;
                                    send_buf[1] <= pram[recv_buf[2]];
                                    send_length <= 4'd2;
                                end

                                CUDA_SET_PRAM: begin
                                    pram[recv_buf[2]] <= recv_buf[3];
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                end

                                CUDA_RESET_SYSTEM: begin
                                    reset_680x0 <= 1'b1;
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                end

                                default: begin
                                    // Unknown command - just acknowledge
                                    send_buf[0] <= PKT_ERROR;
                                    send_length <= 4'd1;
                                    /* verilator lint_off STMTDLY */
                                    $display("CUDA: Unknown CUDA cmd 0x%02x", recv_buf[1]);
                                    /* verilator lint_on STMTDLY */
                                end
                            endcase
                        end

                        PKT_ADB: begin
                            // ADB command - for now just acknowledge
                            // Real implementation would talk to ADB devices
                            send_buf[0] <= PKT_ADB;
                            send_buf[1] <= 8'h00;  // No device response
                            send_length <= 4'd2;
                            /* verilator lint_off STMTDLY */
                            $display("CUDA: ADB command 0x%02x", recv_buf[1]);
                            /* verilator lint_on STMTDLY */
                        end

                        default: begin
                            // Unknown packet type
                            send_buf[0] <= PKT_ERROR;
                            send_length <= 4'd1;
                        end
                    endcase

                    send_count <= 4'h0;
                    treq_reg <= 1'b1;  // Assert TREQ to indicate we have a response
                end

                ST_SEND_WAIT: begin
                    // Keep TREQ asserted while we have data to send
                    treq_reg <= 1'b1;
                    bit_counter <= 4'h0;
                    shift_clk_div <= 8'h0;
                    // Start cb1 low so first toggle creates auto-trigger rising edge for VIA
                    cb1_out <= 1'b0;

                    // Wait counter for ROM to configure VIA before we start clocking
                    // Reset on state entry, increment each cycle
                    if (prev_state != ST_SEND_WAIT)
                        wait_counter <= 16'h0;
                    else if (!via_tip)  // Only count when TIP is asserted
                        wait_counter <= wait_counter + 1'd1;

                    // Prepare byte to send
                    if (send_count < send_length) begin
                        shift_reg <= send_buf[send_count[3:0]];
                        cb2_out_reg <= send_buf[send_count[3:0]][7];  // MSB first
                        cb2_oe_reg <= 1'b1;
                    end else begin
                        cb2_oe_reg <= 1'b0;
                    end
                end

                ST_SEND_BYTE: begin
                    cb2_oe_reg <= 1'b1;

                    // Continue clocking until bit_counter=8 AND cb1 is high (final rising edge done)
                    if (!(bit_counter >= 4'd8 && cb1_out)) begin
                        shift_clk_div <= shift_clk_div + 1'd1;

                        // Clock slow enough for VIA to sample on E clock edges
                        // E clock is ~clk32/40, so we need each CB1 level to last at least 40+ clk8 cycles
                        // div 16 = 16 clk8_en per toggle = 64 clk32 per toggle, ~1.5 E periods
                        if (shift_clk_div >= 8'd16) begin
                            shift_clk_div <= 8'h0;
                            cb1_out <= ~cb1_out;

                            if (cb1_out) begin  // Falling edge - inc counter, prepare next bit
                                if (bit_counter < 4'd8) begin
                                    bit_counter <= bit_counter + 1'd1;
`ifdef SIMULATION
                                    $display("CUDA: ST_SEND_BYTE falling edge - bit_counter %d -> %d, cb1_out=%b", bit_counter, bit_counter + 1, cb1_out);
`endif
                                end
                                if (bit_counter > 0 && bit_counter < 4'd8) begin
                                    shift_reg <= {shift_reg[6:0], 1'b0};
                                    cb2_out_reg <= shift_reg[6];
                                end
                            end
                        end
                    end
                end

                ST_SEND_DONE: begin
                    cb2_oe_reg <= 1'b1;
                    cuda_sr_irq <= 1'b1;
                    bit_counter <= 4'h0;

                    // Increment send_count only on state entry (not every cycle)
                    // Use prev_state to detect first cycle in this state
                    if (prev_state == ST_SEND_BYTE) begin
                        send_count <= send_count + 1'd1;
                        // Prepare next byte if needed, or de-assert TREQ if done
                        if (send_count + 1 < send_length) begin
                            shift_reg <= send_buf[send_count[3:0] + 1];
                            cb2_out_reg <= send_buf[send_count[3:0] + 1][7];
                        end else begin
                            // All bytes sent - de-assert TREQ immediately
                            // ROM checks TREQ between bytes to know if more data is coming
                            treq_reg <= 1'b0;
`ifdef SIMULATION
                            $display("CUDA: SEND_DONE - all bytes sent, de-asserting TREQ");
`endif
                        end
                    end
                end

                ST_FINISH: begin
                    cb2_oe_reg <= 1'b1;  // Keep driving until fully done
                    treq_reg <= 1'b0;    // Ensure TREQ is de-asserted
                    wait_counter <= wait_counter + 1'd1;
                end
            endcase
        end
    end

endmodule
