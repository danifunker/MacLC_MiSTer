/*
 * Behavioral Egret for Mac LC
 *
 * Replaces the real 68HC05 CPU + Egret firmware with a simple state machine.
 * Handles: 68020 reset release, PRAM, RTC, ADB stubs, pseudo-commands.
 *
 * Protocol: VIA shift register with external clock (CB1 driven by Egret).
 *   Host→Egret: VIA mode 7 (shift out ext clk). VIA rotates SR on CB1 falling.
 *                CB2 = SR[7] always. Egret samples CB2 before each rising edge.
 *   Egret→Host: VIA mode 3 (shift in ext clk). VIA shifts CB2 into SR on CB1 rising.
 *                Egret drives CB2, then provides rising edge.
 *   Both: 8 rising edges per byte. After 8th rising, VIA sets IFR[2].
 *
 * Egret protocol signals (from Apple EgretMgr.a / egretequ.a):
 *   PB3 = xcvrSes (XCVR_SESSION) — Egret's session line
 *         Egret drives LOW (0) to indicate it has data to send
 *         HIGH (1) = idle / end of response
 *   PB4 = viaFull (VIA_FULL) — Host byte acknowledge
 *         Host drives HIGH (1) after reading each byte = "got it"
 *         Host drives LOW (0) when ready for next byte
 *   PB5 = sysSes (SYS_SESSION) — Host's session line
 *         Host drives HIGH (1) = session in progress
 *         Host drives LOW (0) = idle
 *
 * Signal mapping to module ports:
 *   cuda_treq=1 → PB3 pin LOW → xcvrSes asserted (Egret has data)
 *   via_tip (via_tip_latched) = PB5 value = sysSes
 *   via_byteack_in = PB4 value = viaFull
 */

module egret_behavioral (
    input  wire        clk,
    input  wire        clk8_en,
    input  wire        reset,

    // RTC timestamp
    input  wire [32:0] timestamp,

    // VIA Port B
    input  wire        via_tip,           // PB5 = sysSes (1=session active)
    input  wire        via_byteack_in,    // PB4 = viaFull (1=host ack'd byte)
    output wire        cuda_treq,         // PB3 inverted: 1=assert xcvrSes (pin LOW)
    output wire        cuda_byteack,

    // VIA Shift Register (CB1/CB2)
    output reg         cuda_cb1,
    input  wire        via_cb2_in,
    output reg         cuda_cb2,
    output reg         cuda_cb2_oe,

    // VIA SR control
    input  wire        via_sr_read,
    input  wire        via_sr_write,
    input  wire        via_sr_ext_clk,
    input  wire        via_sr_dir,       // 0=in (Egret→Host), 1=out (Host→Egret)
    output reg         cuda_sr_irq,

    // Full Port B (minimal)
    output wire [7:0]  cuda_portb,
    output wire [7:0]  cuda_portb_oe,

    // ADB
    input  wire        adb_data_in,
    output wire        adb_data_out,

    // System control
    output reg         reset_680x0,
    output reg         nmi_680x0,

    // Debug (match egret_wrapper interface)
    output wire        dbg_cen,
    output wire        dbg_port_test_done,
    output wire        dbg_handshake_done,
    output wire        dbg_treq,
    output wire        dbg_tip_in,
    output wire        dbg_byteack_in,
    output wire [7:0]  dbg_pb_out,
    output wire [7:0]  dbg_pc_out,
    output wire        dbg_cpu_running
);

    // =========================================================================
    // Constants
    // =========================================================================

    // Boot delay: ~8192 clk8_en ticks before releasing 68020 reset
    localparam BOOT_DELAY = 16'd8192;

    // CB1 half-period in clk8_en ticks (~4µs per half = ~125 kHz bit clock)
    localparam CB1_HALF_PERIOD = 6'd32;

    // Packet types
    localparam [7:0] PKT_ADB   = 8'h00;
    localparam [7:0] PKT_PSEUDO = 8'h01;
    localparam [7:0] PKT_ERROR = 8'h02;

    // Pseudo-command codes (Egret uses same as CUDA)
    localparam [7:0] CMD_WARM_START    = 8'h00;
    localparam [7:0] CMD_AUTOPOLL      = 8'h01;
    localparam [7:0] CMD_GET_TIME      = 8'h03;
    localparam [7:0] CMD_GET_PRAM      = 8'h07;
    localparam [7:0] CMD_SET_TIME      = 8'h09;
    localparam [7:0] CMD_SET_PRAM      = 8'h0C;
    localparam [7:0] CMD_SEND_DFAC     = 8'h0E;
    localparam [7:0] CMD_RESET_SYSTEM  = 8'h11;
    localparam [7:0] CMD_SET_IPL       = 8'h12;
    localparam [7:0] CMD_SET_AUTO_RATE = 8'h14;
    localparam [7:0] CMD_GET_AUTO_RATE = 8'h16;
    localparam [7:0] CMD_SET_DEV_LIST  = 8'h19;
    localparam [7:0] CMD_GET_DEV_LIST  = 8'h1A;
    localparam [7:0] CMD_SET_ONE_SEC   = 8'h1B;
    localparam [7:0] CMD_GET_SET_IIC   = 8'h22;

    // =========================================================================
    // State machine
    // =========================================================================

    // Receive states (host → Egret)
    localparam [3:0] ST_BOOT          = 4'd0;
    localparam [3:0] ST_IDLE          = 4'd1;
    localparam [3:0] ST_RECV_START    = 4'd2;
    localparam [3:0] ST_RECV_CLOCK    = 4'd3;
    localparam [3:0] ST_RECV_DONE     = 4'd4;
    localparam [3:0] ST_PROCESS       = 4'd5;
    // Send states (Egret → host) — Egret protocol with xcvrSes/viaFull/sysSes
    localparam [3:0] ST_SEND_ATTN     = 4'd6;  // Clock attention byte, wait for sysSes
    localparam [3:0] ST_SEND_WAIT_ACK = 4'd7;  // Wait for viaFull ack from host
    localparam [3:0] ST_SEND_CLOCK    = 4'd8;  // Clock 8 bits out via CB1/CB2
    localparam [3:0] ST_SEND_WAIT_VIAFULL = 4'd9;  // Wait for host to set viaFull after byte
    localparam [3:0] ST_FINISH        = 4'd10;

    reg [3:0]  state;

    // =========================================================================
    // Registers
    // =========================================================================

    // Synchronizer for inputs
    reg [2:0] tip_sync;
    wire      tip = tip_sync[2];        // sysSes: 1=session active
    reg       tip_prev;

    reg [2:0] viafull_sync;
    wire      viafull = viafull_sync[2]; // viaFull: 1=host ack'd byte
    reg       viafull_prev;

    // Edge detection
    reg       sr_write_prev;
    reg       sr_read_prev;

    // Boot counter
    reg [15:0] boot_counter;

    // CB1 clock divider
    reg [5:0]  clk_div;

    // Shift state
    reg [7:0]  shift_data;
    reg [3:0]  bit_count;       // 0..8 for clocking, counts rising edges
    reg        sample_phase;    // 0 = drive CB2/sample, 1 = rising edge

    // Buffers
    reg [7:0]  recv_buf [0:15];
    reg [3:0]  recv_count;
    reg [7:0]  send_buf [0:15];
    reg [3:0]  send_count;
    reg [3:0]  send_length;

    // xcvrSes output (active-high = pulling PB3 pin low = "I have data")
    reg        treq_reg;

    // Wait counter for timeouts
    reg [15:0] wait_counter;

    // SR write pending (host wrote SR, needs clocking)
    reg        sr_write_pending;

    // PRAM
    reg [7:0]  pram [0:255];

    // RTC
    localparam [31:0] MAC_UNIX_DELTA = 32'd2082844800;
    reg [31:0] rtc_seconds;
    reg [23:0] rtc_tick;
    reg        rtc_init;

    // =========================================================================
    // Output assignments
    // =========================================================================

    assign cuda_treq     = treq_reg;       // 1 = assert xcvrSes (PB3 pin LOW)
    assign cuda_byteack  = 1'b0;           // Not used for Egret
    assign cuda_portb    = {2'b11, 1'b0, treq_reg, 4'b1111};
    assign cuda_portb_oe = 8'b00001000;    // Only xcvrSes/TREQ is output
    assign adb_data_out  = 1'b1;

    // Debug
    assign dbg_cen             = clk8_en;
    assign dbg_port_test_done  = (state != ST_BOOT);
    assign dbg_handshake_done  = (state != ST_BOOT);
    assign dbg_treq            = treq_reg;
    assign dbg_tip_in          = tip;
    assign dbg_byteack_in      = viafull;
    assign dbg_pb_out          = cuda_portb;
    assign dbg_pc_out          = {4'b0, state};
    assign dbg_cpu_running     = (state != ST_BOOT);

    // =========================================================================
    // PRAM init
    // =========================================================================

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            pram[i] = 8'h00;
        pram[8'h08] = 8'h00;
        pram[8'h09] = 8'h08;
        pram[8'h10] = 8'h02;  // 4bpp
        pram[8'h78] = 8'h07;  // Volume
        pram[8'h7C] = 8'hA8;  // PRAM signature
        pram[8'h7D] = 8'h00;
        pram[8'h7E] = 8'h00;
        pram[8'h7F] = 8'h01;
    end

    // =========================================================================
    // Main state machine
    //
    // Egret protocol (from Apple EgretMgr.a):
    //
    // HOST SEND (command):
    //   1. Host asserts sysSes (PB5=1), sets VIA to shift-out, writes SR, sets viaFull
    //   2. Egret clocks byte via CB1 edges, host waits for IFR[2]
    //   3. Host clears viaFull, delays, writes next byte, sets viaFull
    //   4. After last byte: host clears sysSes + viaFull
    //
    // HOST RECEIVE (response via ShiftRegIRQ):
    //   1. Egret asserts xcvrSes (PB3=0) = "I have data"
    //   2. Egret clocks attention byte via CB1 → VIA SR IRQ fires
    //   3. Host reads vSR (clears IFR[2]), delays 100us (first byte = no viaFull ack)
    //   4. Host asserts sysSes (PB5=1) = "OK, continue sending"
    //   5. Egret clocks next byte → VIA SR IRQ
    //   6. Host reads vSR, sets viaFull (PB4=1) = "got it", delays, clears viaFull
    //   7. Host checks xcvrSes: if PB3=1 (HIGH) → Egret done, go to @done
    //   8. If more bytes: return from ISR, Egret clocks next byte
    //   9. @done: host clears viaFull, clears sysSes, delays
    //
    // HOST RECEIVE (register-based, during boot via SendEgretCmd):
    //   1. Egret clocks attention byte → host polls IFR[2], reads vSR (discard)
    //   2. Host delays, asserts sysSes (PB5=1)
    //   3. Egret clocks data byte → host polls IFR[2]
    //   4. Host sets viaFull (PB4=1), reads vSR, delays, clears viaFull
    //   5. Host checks xcvrSes (PB3) — if HIGH, done
    //   6. Repeat from 3
    //   7. When done: host clears sysSes
    //
    // =========================================================================

    always @(posedge clk) begin
        if (reset) begin
            state          <= ST_BOOT;
            tip_sync       <= 3'b000;
            tip_prev       <= 1'b0;
            viafull_sync   <= 3'b000;
            viafull_prev   <= 1'b0;
            sr_write_prev  <= 1'b0;
            sr_read_prev   <= 1'b0;
            boot_counter   <= 16'd0;
            reset_680x0    <= 1'b1;   // Hold 68020 in reset
            nmi_680x0      <= 1'b0;
            treq_reg       <= 1'b0;
            cuda_cb1       <= 1'b0;
            cuda_cb2       <= 1'b0;
            cuda_cb2_oe    <= 1'b0;
            cuda_sr_irq    <= 1'b0;
            clk_div        <= 6'd0;
            bit_count      <= 4'd0;
            sample_phase   <= 1'b0;
            shift_data     <= 8'd0;
            recv_count     <= 4'd0;
            send_count     <= 4'd0;
            send_length    <= 4'd0;
            wait_counter   <= 16'd0;
            sr_write_pending <= 1'b0;
            rtc_seconds    <= 32'd0;
            rtc_tick       <= 24'd0;
            rtc_init       <= 1'b0;

        end else if (clk8_en) begin
            // Synchronize inputs
            tip_sync     <= {tip_sync[1:0], via_tip};
            tip_prev     <= tip;
            viafull_sync <= {viafull_sync[1:0], via_byteack_in};
            viafull_prev <= viafull;
            sr_write_prev <= via_sr_write;
            sr_read_prev  <= via_sr_read;

            // Default: clear one-shot signals
            cuda_sr_irq <= 1'b0;

            // RTC
            if (!rtc_init && timestamp != 0) begin
                rtc_seconds <= timestamp[31:0] + MAC_UNIX_DELTA;
                rtc_init    <= 1'b1;
            end else begin
                if (rtc_tick >= 24'd7_999_999) begin
                    rtc_tick    <= 24'd0;
                    rtc_seconds <= rtc_seconds + 1'd1;
                end else begin
                    rtc_tick <= rtc_tick + 1'd1;
                end
            end

            // Track SR write from host
            if (via_sr_write && !sr_write_prev)
                sr_write_pending <= 1'b1;

            // ---- State machine ----
            case (state)

            // ==== BOOT: hold 68020 in reset, then release ====
            ST_BOOT: begin
                boot_counter <= boot_counter + 1'd1;
                if (boot_counter == BOOT_DELAY) begin
                    reset_680x0 <= 1'b0;  // Release 68020
`ifdef SIMULATION
                    $display("EGRET_BEH: Released 68020 reset at tick %0d", boot_counter);
`endif
                end
                if (boot_counter >= BOOT_DELAY + 16'd100) begin
                    state <= ST_IDLE;
`ifdef SIMULATION
                    $display("EGRET_BEH: Entering IDLE");
`endif
                end
            end

            // ==== IDLE: wait for host to assert sysSes (start transaction) ====
            ST_IDLE: begin
                treq_reg    <= 1'b0;   // xcvrSes deasserted (PB3=1, idle)
                cuda_cb1    <= 1'b0;
                cuda_cb2_oe <= 1'b0;
                recv_count  <= 4'd0;
                send_count  <= 4'd0;

                // Host asserts sysSes (PB5=1) → start receiving command
                if (tip && !tip_prev) begin
                    state        <= ST_RECV_START;
                    wait_counter <= 16'd0;
                    sr_write_pending <= 1'b0;
`ifdef SIMULATION
                    $display("EGRET_BEH: sysSes asserted, entering RECV_START");
`endif
                end
            end

            // ==== RECV_START: wait for host to write SR (viaFull set) ====
            ST_RECV_START: begin
                wait_counter <= wait_counter + 1'd1;

                if (sr_write_pending) begin
                    // Host wrote SR, start clocking
                    sr_write_pending <= 1'b0;
                    state        <= ST_RECV_CLOCK;
                    clk_div      <= 6'd0;
                    bit_count    <= 4'd0;
                    sample_phase <= 1'b0;
                    shift_data   <= 8'd0;
                    cuda_cb1     <= 1'b0;
`ifdef SIMULATION
                    $display("EGRET_BEH: SR written, entering RECV_CLOCK (byte %0d)", recv_count);
`endif
                end else if (!tip) begin
                    // sysSes deasserted — end of command packet
                    if (recv_count > 0) begin
                        state <= ST_PROCESS;
`ifdef SIMULATION
                        $display("EGRET_BEH: sysSes deasserted in RECV_START, processing %0d bytes", recv_count);
`endif
                    end else begin
                        state <= ST_IDLE;
                    end
                end else if (wait_counter >= 16'd50000) begin
                    if (recv_count > 0)
                        state <= ST_PROCESS;
                    else
                        state <= ST_IDLE;
                end
            end

            // ==== RECV_CLOCK: clock 8 bits from VIA SR (mode 7 = shift out ext) ====
            ST_RECV_CLOCK: begin
                clk_div <= clk_div + 1'd1;

                if (clk_div >= CB1_HALF_PERIOD) begin
                    clk_div <= 6'd0;

                    if (!sample_phase) begin
                        // Phase 0: Sample CB2 (data bit), raise CB1
                        shift_data <= {shift_data[6:0], via_cb2_in};
                        sample_phase <= 1'b1;
                        cuda_cb1 <= 1'b1;
                        bit_count <= bit_count + 1'd1;
`ifdef SIMULATION
                        $display("EGRET_BEH: RECV bit[%0d] cb2=%b shift=0x%02x (byte %0d)",
                                 bit_count, via_cb2_in, {shift_data[6:0], via_cb2_in}, recv_count);
`endif
                    end else begin
                        // Phase 1: Lower CB1 (falling edge → VIA rotates SR)
                        cuda_cb1 <= 1'b0;
                        sample_phase <= 1'b0;

                        if (bit_count >= 4'd8) begin
                            recv_buf[recv_count] <= shift_data;
                            recv_count <= recv_count + 1'd1;
                            state <= ST_RECV_DONE;
                            wait_counter <= 16'd0;
`ifdef SIMULATION
                            $display("EGRET_BEH: RECV byte[%0d] = 0x%02x", recv_count, shift_data);
`endif
                        end
                    end
                end
            end

            // ==== RECV_DONE: wait for host to ack (viaFull toggle or SR write) ====
            // In Egret protocol, host does viaFullAck (set PB4) then clears it.
            // Or host writes next byte to SR. Or host deasserts sysSes.
            ST_RECV_DONE: begin
                wait_counter <= wait_counter + 1'd1;

                if (!tip) begin
                    // sysSes deasserted → end of command packet
                    state <= ST_PROCESS;
`ifdef SIMULATION
                    $display("EGRET_BEH: sysSes deasserted after byte %0d, processing", recv_count);
`endif
                end else if (sr_write_pending) begin
                    // Host wrote next byte to SR
                    sr_write_pending <= 1'b0;
                    state        <= ST_RECV_CLOCK;
                    clk_div      <= 6'd0;
                    bit_count    <= 4'd0;
                    sample_phase <= 1'b0;
                    shift_data   <= 8'd0;
                    cuda_cb1     <= 1'b0;
                end else if (wait_counter >= 16'd50000) begin
                    state <= ST_PROCESS;
                end
            end

            // ==== PROCESS: decode command, build response ====
            ST_PROCESS: begin
`ifdef SIMULATION
                $display("EGRET_BEH: PROCESS pkt_type=0x%02x cmd=0x%02x recv_count=%0d",
                         recv_buf[0], recv_buf[1], recv_count);
`endif
                send_count  <= 4'd0;

                // Response format: [type, flags, cmd_echo, data...]
                // - type: echo original packet type ($01=pseudo, $00=ADB)
                //         $02=error only for actual errors
                // - flags: $00 for success
                // - cmd_echo: echo of the command byte
                // - data: optional payload bytes
                // Attention byte ($01) is sent separately in ST_SEND_ATTN.
                // Minimum 3 bytes (type + flags + cmd).

                case (recv_buf[0])
                PKT_PSEUDO: begin
                    // Common header for all pseudo responses
                    send_buf[0] <= PKT_PSEUDO;       // type echo
                    send_buf[1] <= 8'h00;             // flags (success)
                    send_buf[2] <= recv_buf[1];       // command echo

                    case (recv_buf[1])
                    CMD_WARM_START: begin
                        send_length <= 4'd3;
                    end

                    CMD_AUTOPOLL: begin
                        send_length <= 4'd3;
                    end

                    CMD_GET_TIME: begin
                        send_buf[3] <= rtc_seconds[31:24];
                        send_buf[4] <= rtc_seconds[23:16];
                        send_buf[5] <= rtc_seconds[15:8];
                        send_buf[6] <= rtc_seconds[7:0];
                        send_length <= 4'd7;
                    end

                    CMD_SET_TIME: begin
                        rtc_seconds <= {recv_buf[2], recv_buf[3], recv_buf[4], recv_buf[5]};
                        send_length <= 4'd3;
                    end

                    CMD_GET_PRAM: begin
                        send_buf[3] <= pram[recv_buf[3]];
                        send_length <= 4'd4;
`ifdef SIMULATION
                        $display("EGRET_BEH: GET_PRAM[0x%02x] = 0x%02x",
                                 recv_buf[3], pram[recv_buf[3]]);
`endif
                    end

                    CMD_SET_PRAM: begin
                        pram[recv_buf[3]] <= recv_buf[4];
                        send_length <= 4'd3;
`ifdef SIMULATION
                        $display("EGRET_BEH: SET_PRAM[0x%02x] = 0x%02x", recv_buf[3], recv_buf[4]);
`endif
                    end

                    CMD_SEND_DFAC: begin
                        send_length <= 4'd3;
                    end

                    CMD_RESET_SYSTEM: begin
                        reset_680x0 <= 1'b1;
                        send_length <= 4'd3;
                    end

                    CMD_SET_IPL: begin
                        send_length <= 4'd3;
                    end

                    CMD_GET_DEV_LIST: begin
                        send_buf[3] <= 8'h00;
                        send_buf[4] <= 8'h00;
                        send_length <= 4'd5;
                    end

                    CMD_SET_DEV_LIST: begin
                        send_length <= 4'd3;
                    end

                    CMD_SET_ONE_SEC: begin
                        send_length <= 4'd3;
                    end

                    CMD_SET_AUTO_RATE: begin
                        send_length <= 4'd3;
                    end

                    CMD_GET_AUTO_RATE: begin
                        send_buf[3] <= 8'h0B;
                        send_length <= 4'd4;
                    end

                    CMD_GET_SET_IIC: begin
                        send_length <= 4'd3;
                    end

                    default: begin
                        send_length <= 4'd3;
`ifdef SIMULATION
                        $display("EGRET_BEH: Unknown pseudo-cmd 0x%02x, returning OK", recv_buf[1]);
`endif
                    end
                    endcase
                end

                PKT_ADB: begin
                    send_buf[0] <= PKT_ADB;
                    send_buf[1] <= 8'h00;       // flags
                    send_buf[2] <= recv_buf[1];  // cmd echo
                    send_length <= 4'd3;
                end

                default: begin
                    send_buf[0] <= PKT_ERROR;
                    send_buf[1] <= 8'h00;
                    send_buf[2] <= recv_buf[1];
                    send_length <= 4'd3;
                end
                endcase

                // Begin response: assert xcvrSes (PB3 LOW) and clock attention byte
                // The attention byte ($01 for pseudo response) wakes up the host via SR IRQ.
                // In Egret protocol, the first byte clocked IS the notification — no separate
                // "SEND_NOTIFY" needed. The host ISR (or polling loop) picks it up.
                treq_reg      <= 1'b1;  // Assert xcvrSes = "I have data"
                state         <= ST_SEND_ATTN;
                clk_div       <= 6'd0;
                bit_count     <= 4'd0;
                sample_phase  <= 1'b0;
                // Attention byte = $01 (always, for Egret response)
                shift_data    <= 8'h01;
                cuda_cb2      <= 1'b1;  // MSB of $01 = 0... wait, $01 = 00000001, MSB=0
                cuda_cb2_oe   <= 1'b1;
                cuda_cb1      <= 1'b0;
                wait_counter  <= 16'd0;
`ifdef SIMULATION
                $display("EGRET_BEH: Starting response, asserting xcvrSes, clocking attn byte $01");
`endif
            end

            // ==== SEND_ATTN: Clock the attention byte ($01) ====
            // After 8 bits, VIA IFR[2] fires. Host reads SR (gets $01), then:
            //   - ISR path: checks sysSes, delays 100us, asserts sysSes
            //   - Register path: discards byte, delays, asserts sysSes
            // Egret waits for sysSes (PB5=1) before sending data bytes.
            ST_SEND_ATTN: begin
                clk_div <= clk_div + 1'd1;

                if (clk_div >= CB1_HALF_PERIOD) begin
                    clk_div <= 6'd0;

                    if (!sample_phase) begin
                        // Drive CB2 with data bit, raise CB1 (VIA shifts in on rising)
                        cuda_cb2 <= shift_data[7];
                        cuda_cb1  <= 1'b1;
                        bit_count <= bit_count + 1'd1;
                        sample_phase <= 1'b1;
                    end else begin
                        // Lower CB1, shift to next bit
                        cuda_cb1 <= 1'b0;
                        sample_phase <= 1'b0;
                        shift_data <= {shift_data[6:0], 1'b0};

                        if (bit_count >= 4'd8) begin
                            // Attention byte clocked — wait for host sysSes
                            state <= ST_SEND_WAIT_ACK;
                            wait_counter <= 16'd0;
`ifdef SIMULATION
                            $display("EGRET_BEH: Attention byte $01 clocked, waiting for sysSes");
`endif
                        end
                    end
                end
            end

            // ==== SEND_WAIT_ACK: Wait for host to assert sysSes after attention byte ====
            // Host ISR: delay 100us, bset #sysSes,vBufB → PB5=1
            // Register path: delay, bset #sysSes,vBufB → PB5=1
            ST_SEND_WAIT_ACK: begin
                wait_counter <= wait_counter + 1'd1;
                cuda_cb1 <= 1'b0;

                if (tip) begin
                    // Host asserted sysSes — start sending data bytes
                    // Small delay for VIA to settle
                    if (wait_counter >= 16'd20) begin
                        state        <= ST_SEND_CLOCK;
                        clk_div      <= 6'd0;
                        bit_count    <= 4'd0;
                        sample_phase <= 1'b0;
                        shift_data   <= send_buf[0];
                        cuda_cb2     <= send_buf[0][7];
                        cuda_cb2_oe  <= 1'b1;
`ifdef SIMULATION
                        $display("EGRET_BEH: sysSes asserted, sending byte[0] = 0x%02x", send_buf[0]);
`endif
                    end
                end else if (wait_counter >= 16'd100000) begin
                    // Timeout
                    treq_reg <= 1'b0;
                    state    <= ST_IDLE;
`ifdef SIMULATION
                    $display("EGRET_BEH: SEND_WAIT_ACK timeout, returning to IDLE");
`endif
                end
            end

            // ==== SEND_CLOCK: clock 8 bits to VIA SR (mode 3 = shift in ext) ====
            ST_SEND_CLOCK: begin
                clk_div <= clk_div + 1'd1;

                if (clk_div >= CB1_HALF_PERIOD) begin
                    clk_div <= 6'd0;

                    if (!sample_phase) begin
                        // Phase 0: CB2 has data, raise CB1 (VIA shifts in)
                        cuda_cb2  <= shift_data[7];
                        cuda_cb1  <= 1'b1;
                        bit_count <= bit_count + 1'd1;
                        sample_phase <= 1'b1;
                    end else begin
                        // Phase 1: Lower CB1, advance to next bit
                        cuda_cb1 <= 1'b0;
                        sample_phase <= 1'b0;
                        shift_data <= {shift_data[6:0], 1'b0};

                        if (bit_count >= 4'd8) begin
                            // Byte complete — IFR[2] fires in VIA
                            send_count <= send_count + 1'd1;
                            wait_counter <= 16'd0;

                            if (send_count + 1'd1 >= send_length) begin
                                // Last byte just sent — deassert xcvrSes BEFORE host checks
                                // Host will do viaFullAck, then check xcvrSes → sees HIGH → @done
                                treq_reg <= 1'b0;  // Deassert xcvrSes (PB3=1)
                                state <= ST_SEND_WAIT_VIAFULL;
`ifdef SIMULATION
                                $display("EGRET_BEH: Last byte[%0d] = 0x%02x sent, xcvrSes deasserted",
                                         send_count, send_buf[send_count]);
`endif
                            end else begin
                                // More bytes to send — keep xcvrSes asserted
                                state <= ST_SEND_WAIT_VIAFULL;
`ifdef SIMULATION
                                $display("EGRET_BEH: Byte[%0d] = 0x%02x sent, waiting for viaFull ack",
                                         send_count, send_buf[send_count]);
`endif
                            end
                        end
                    end
                end
            end

            // ==== SEND_WAIT_VIAFULL: Wait for host viaFull (PB4) ack after each byte ====
            // Egret protocol: host sets viaFull (PB4=1), delays 100us, then clears it
            // on ISR exit. We detect the rising edge of viaFull, then wait for it to
            // clear before sending the next byte.
            //
            // For the last byte, xcvrSes is already deasserted. Host does viaFullAck,
            // checks xcvrSes=1 → goes to @done, clears viaFull + sysSes.
            ST_SEND_WAIT_VIAFULL: begin
                wait_counter <= wait_counter + 1'd1;
                cuda_cb1 <= 1'b0;

                if (!tip) begin
                    // Host deasserted sysSes — transaction done
                    treq_reg <= 1'b0;
                    state <= ST_FINISH;
                    wait_counter <= 16'd0;
`ifdef SIMULATION
                    $display("EGRET_BEH: sysSes deasserted (sent %0d/%0d), transaction done",
                             send_count, send_length);
`endif
                end else if (viafull && !viafull_prev) begin
                    // Host set viaFull (PB4 rising) = acknowledged byte
                    // Now wait for viaFull to clear before sending next byte
                    if (send_count >= send_length) begin
                        // Last byte was ack'd — host will check xcvrSes=1 → @done
                        // Wait for sysSes to deassert (host finishes @done path)
                        // Already in this state, just keep waiting for !tip
`ifdef SIMULATION
                        $display("EGRET_BEH: Last byte ack'd (viaFull), waiting for sysSes deassert");
`endif
                    end
                    // For non-last bytes, we wait for viaFull to drop, then send next
                end else if (!viafull && viafull_prev && send_count < send_length) begin
                    // viaFull cleared (PB4 falling) — host is ready for next byte
                    state        <= ST_SEND_CLOCK;
                    clk_div      <= 6'd0;
                    bit_count    <= 4'd0;
                    sample_phase <= 1'b0;
                    shift_data   <= send_buf[send_count];
                    cuda_cb2     <= send_buf[send_count][7];
                    cuda_cb2_oe  <= 1'b1;
`ifdef SIMULATION
                    $display("EGRET_BEH: viaFull cleared, sending byte[%0d] = 0x%02x",
                             send_count, send_buf[send_count]);
`endif
                end else if (wait_counter >= 16'd100000) begin
                    // Timeout
                    treq_reg <= 1'b0;
                    state <= ST_IDLE;
`ifdef SIMULATION
                    $display("EGRET_BEH: SEND_WAIT_VIAFULL timeout (sent %0d/%0d)",
                             send_count, send_length);
`endif
                end
            end

            // ==== FINISH: clean up, return to IDLE ====
            ST_FINISH: begin
                wait_counter <= wait_counter + 1'd1;
                treq_reg    <= 1'b0;
                cuda_cb1    <= 1'b0;
                cuda_cb2_oe <= 1'b0;

                if (wait_counter >= 16'd100) begin
                    state <= ST_IDLE;
`ifdef SIMULATION
                    $display("EGRET_BEH: Transaction complete, returning to IDLE");
`endif
                end
            end

            default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
