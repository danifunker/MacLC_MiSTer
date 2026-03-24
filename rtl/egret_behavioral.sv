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
 * TIP polarity (Egret, NOT CUDA):
 *   via_tip=1 → TIP active (session in progress)
 *   via_tip=0 → TIP idle
 *
 * TREQ: cuda_treq=1 → pulling PB3 low → TREQ asserted (device has data)
 */

module egret_behavioral (
    input  wire        clk,
    input  wire        clk8_en,
    input  wire        reset,

    // RTC timestamp
    input  wire [32:0] timestamp,

    // VIA Port B
    input  wire        via_tip,
    input  wire        via_byteack_in,
    output wire        cuda_treq,
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

    localparam [3:0] ST_BOOT          = 4'd0;
    localparam [3:0] ST_IDLE          = 4'd1;
    localparam [3:0] ST_RECV_START    = 4'd2;
    localparam [3:0] ST_RECV_CLOCK    = 4'd3;
    localparam [3:0] ST_RECV_DONE     = 4'd4;
    localparam [3:0] ST_PROCESS       = 4'd5;
    localparam [3:0] ST_SEND_NOTIFY   = 4'd6;  // Clock 8 dummy CB1 edges to trigger IFR[2]
    localparam [3:0] ST_SEND_TREQ     = 4'd7;
    localparam [3:0] ST_SEND_CLOCK    = 4'd8;
    localparam [3:0] ST_SEND_DONE     = 4'd9;
    localparam [3:0] ST_FINISH        = 4'd10;

    reg [3:0]  state;

    // =========================================================================
    // Registers
    // =========================================================================

    // Synchronizer for TIP
    reg [2:0] tip_sync;
    wire      tip = tip_sync[2];
    reg       tip_prev;

    // Edge detection
    reg       sr_write_prev;
    reg       sr_read_prev;
    reg       byteack_prev;

    // Boot counter
    reg [15:0] boot_counter;

    // CB1 clock divider
    reg [5:0]  clk_div;

    // Shift state
    reg [7:0]  shift_data;
    reg [3:0]  bit_count;       // 0..8 for clocking, counts rising edges
    reg        sample_phase;    // 0 = sample/drive CB2, 1 = rising edge

    // Buffers
    reg [7:0]  recv_buf [0:15];
    reg [3:0]  recv_count;
    reg [7:0]  send_buf [0:15];
    reg [3:0]  send_count;
    reg [3:0]  send_length;

    // TREQ output
    reg        treq_reg;

    // Wait counter for timeouts
    reg [15:0] wait_counter;

    // SR write pending (host wrote SR, needs clocking)
    reg        sr_write_pending;

    // After SEND_NOTIFY: go to SEND_TREQ (0) or FINISH (1)
    reg        notify_is_end;

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

    assign cuda_treq     = treq_reg;
    assign cuda_byteack  = 1'b0;  // Not used for Egret
    assign cuda_portb    = {2'b11, 1'b0, treq_reg, 4'b1111};
    assign cuda_portb_oe = 8'b00001000;  // Only TREQ is output
    assign adb_data_out  = 1'b1;

    // Debug
    assign dbg_cen             = clk8_en;
    assign dbg_port_test_done  = (state != ST_BOOT);
    assign dbg_handshake_done  = (state != ST_BOOT);
    assign dbg_treq            = treq_reg;
    assign dbg_tip_in          = tip;
    assign dbg_byteack_in      = via_byteack_in;
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
    // =========================================================================

    always @(posedge clk) begin
        if (reset) begin
            state          <= ST_BOOT;
            tip_sync       <= 3'b000;
            tip_prev       <= 1'b0;
            sr_write_prev  <= 1'b0;
            sr_read_prev   <= 1'b0;
            byteack_prev   <= 1'b0;
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
            notify_is_end  <= 1'b0;
            rtc_seconds    <= 32'd0;
            rtc_tick       <= 24'd0;
            rtc_init       <= 1'b0;

        end else if (clk8_en) begin
            // Synchronize TIP
            tip_sync <= {tip_sync[1:0], via_tip};
            tip_prev <= tip;
            sr_write_prev <= via_sr_write;
            sr_read_prev  <= via_sr_read;
            byteack_prev  <= via_byteack_in;

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

            // ==== IDLE: wait for host transaction ====
            ST_IDLE: begin
                treq_reg    <= 1'b0;
                cuda_cb1    <= 1'b0;
                cuda_cb2_oe <= 1'b0;
                recv_count  <= 4'd0;
                send_count  <= 4'd0;

                // Host asserts TIP → start receiving
                if (tip && !tip_prev) begin
                    state        <= ST_RECV_START;
                    wait_counter <= 16'd0;
                    sr_write_pending <= 1'b0;
`ifdef SIMULATION
                    $display("EGRET_BEH: TIP asserted, entering RECV_START");
`endif
                end
            end

            // ==== RECV_START: wait for host to write SR ====
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
                    // TIP deasserted without SR write — abort or end of transaction
                    if (recv_count > 0) begin
                        state <= ST_PROCESS;
`ifdef SIMULATION
                        $display("EGRET_BEH: TIP deasserted in RECV_START, processing %0d bytes", recv_count);
`endif
                    end else begin
                        state <= ST_IDLE;
                    end
                end else if (wait_counter >= 16'd50000) begin
                    // Timeout
                    if (recv_count > 0)
                        state <= ST_PROCESS;
                    else
                        state <= ST_IDLE;
                end
            end

            // ==== RECV_CLOCK: clock 8 bits from VIA SR (mode 7 = shift out ext) ====
            // VIA rotates SR on CB1 falling edge. CB2 = SR[7] always.
            // Sequence per bit: sample CB2, then provide rising+falling CB1 edge.
            // First sample gets MSB before any rotation.
            ST_RECV_CLOCK: begin
                clk_div <= clk_div + 1'd1;

                if (clk_div >= CB1_HALF_PERIOD) begin
                    clk_div <= 6'd0;

                    if (!sample_phase) begin
                        // Phase 0: Sample CB2 (data bit)
                        shift_data <= {shift_data[6:0], via_cb2_in};
                        sample_phase <= 1'b1;
                        // Immediately raise CB1 (rising edge)
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
                            // All 8 bits received
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

            // ==== RECV_DONE: wait for TACK toggle or TIP deassert ====
            ST_RECV_DONE: begin
                wait_counter <= wait_counter + 1'd1;

                if (!tip) begin
                    // Host deasserted TIP → end of packet
                    state <= ST_PROCESS;
`ifdef SIMULATION
                    $display("EGRET_BEH: TIP deasserted after byte %0d, processing", recv_count);
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

                case (recv_buf[0])
                PKT_PSEUDO: begin
                    case (recv_buf[1])
                    CMD_WARM_START: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_AUTOPOLL: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_GET_TIME: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= CMD_GET_TIME;
                        send_buf[2] <= rtc_seconds[31:24];
                        send_buf[3] <= rtc_seconds[23:16];
                        send_buf[4] <= rtc_seconds[15:8];
                        send_buf[5] <= rtc_seconds[7:0];
                        send_length <= 4'd6;
                    end

                    CMD_SET_TIME: begin
                        rtc_seconds <= {recv_buf[2], recv_buf[3], recv_buf[4], recv_buf[5]};
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_GET_PRAM: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= CMD_GET_PRAM;
                        send_buf[2] <= pram[recv_buf[2]];
                        send_length <= 4'd3;
                    end

                    CMD_SET_PRAM: begin
                        pram[recv_buf[2]] <= recv_buf[3];
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_SEND_DFAC: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_RESET_SYSTEM: begin
                        reset_680x0 <= 1'b1;
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_SET_IPL: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_GET_DEV_LIST: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= CMD_GET_DEV_LIST;
                        send_buf[2] <= 8'h00;
                        send_buf[3] <= 8'h00;
                        send_length <= 4'd4;
                    end

                    CMD_SET_DEV_LIST: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_SET_ONE_SEC: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_SET_AUTO_RATE: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    CMD_GET_AUTO_RATE: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= CMD_GET_AUTO_RATE;
                        send_buf[2] <= 8'h0B;
                        send_length <= 4'd3;
                    end

                    CMD_GET_SET_IIC: begin
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
                    end

                    default: begin
                        // Unknown pseudo-command: acknowledge OK
                        send_buf[0] <= PKT_ERROR;
                        send_buf[1] <= 8'h00;
                        send_length <= 4'd2;
`ifdef SIMULATION
                        $display("EGRET_BEH: Unknown pseudo-cmd 0x%02x, returning OK", recv_buf[1]);
`endif
                    end
                    endcase
                end

                PKT_ADB: begin
                    send_buf[0] <= PKT_ADB;
                    send_buf[1] <= 8'h00;
                    send_length <= 4'd2;
                end

                default: begin
                    send_buf[0] <= PKT_ERROR;
                    send_buf[1] <= 8'h00;
                    send_length <= 4'd2;
                end
                endcase

                // Assert TREQ and clock 8 dummy CB1 edges to notify host via IFR[2]
                treq_reg      <= 1'b1;
                state         <= ST_SEND_NOTIFY;
                clk_div       <= 6'd0;
                bit_count     <= 4'd0;
                sample_phase  <= 1'b0;
                cuda_cb1      <= 1'b0;
                wait_counter  <= 16'd0;
                notify_is_end <= 1'b0;  // After notify → SEND_TREQ
            end

            // ==== SEND_NOTIFY: clock 8 dummy CB1 edges to trigger VIA IFR[2] ====
            // The host is polling IFR bit 2 after the receive phase. We need to
            // provide 8 CB1 rising edges so the VIA's bit counter fires IFR[2],
            // waking the host. Host then reads ORB, sees TREQ, and reconfigures.
            ST_SEND_NOTIFY: begin
                clk_div <= clk_div + 1'd1;
                if (clk_div >= CB1_HALF_PERIOD) begin
                    clk_div <= 6'd0;
                    if (!sample_phase) begin
                        // Rising edge
                        cuda_cb1 <= 1'b1;
                        bit_count <= bit_count + 1'd1;
                        sample_phase <= 1'b1;
                    end else begin
                        // Falling edge
                        cuda_cb1 <= 1'b0;
                        sample_phase <= 1'b0;
                        if (bit_count >= 4'd8) begin
                            // 8 edges done — IFR[2] should fire
                            if (notify_is_end) begin
                                state <= ST_FINISH;
                            end else begin
                                state <= ST_SEND_TREQ;
                            end
                            wait_counter <= 16'd0;
`ifdef SIMULATION
                            $display("EGRET_BEH: SEND_NOTIFY done, 8 dummy edges clocked (end=%b)", notify_is_end);
`endif
                        end
                    end
                end
            end

            // ==== SEND_TREQ: TREQ asserted, wait for host TIP + shift-in mode ====
            ST_SEND_TREQ: begin
                wait_counter <= wait_counter + 1'd1;
                cuda_cb1 <= 1'b0;
`ifdef SIMULATION
                if (wait_counter == 16'd1)
                    $display("EGRET_BEH: SEND_TREQ: treq=%b tip=%b sr_ext=%b sr_dir=%b",
                             treq_reg, tip, via_sr_ext_clk, via_sr_dir);
                if (wait_counter[12:0] == 13'd0 && wait_counter != 16'd0)
                    $display("EGRET_BEH: SEND_TREQ wait %0d: treq=%b tip=%b sr_ext=%b sr_dir=%b",
                             wait_counter, treq_reg, tip, via_sr_ext_clk, via_sr_dir);
`endif

                // Host asserts TIP and sets VIA to shift-in ext clock mode
                if (tip && via_sr_ext_clk && !via_sr_dir) begin
                    // Small delay for VIA to settle
                    if (wait_counter >= 16'd50) begin
                        state        <= ST_SEND_CLOCK;
                        clk_div      <= 6'd0;
                        bit_count    <= 4'd0;
                        sample_phase <= 1'b0;
                        shift_data   <= send_buf[0];
                        cuda_cb2     <= send_buf[0][7];  // MSB first
                        cuda_cb2_oe  <= 1'b1;
`ifdef SIMULATION
                        $display("EGRET_BEH: Sending byte[0] = 0x%02x", send_buf[0]);
`endif
                    end
                end else if (wait_counter >= 16'd100000) begin
                    // Timeout — host never responded
                    treq_reg <= 1'b0;
                    state    <= ST_IDLE;
`ifdef SIMULATION
                    $display("EGRET_BEH: SEND_TREQ timeout, returning to IDLE");
`endif
                end
            end

            // ==== SEND_CLOCK: clock 8 bits to VIA SR (mode 3 = shift in ext) ====
            // Drive CB2 with data bit, then provide rising+falling CB1 edge.
            // VIA shifts CB2 into SR on rising edge.
            ST_SEND_CLOCK: begin
                clk_div <= clk_div + 1'd1;

                if (clk_div >= CB1_HALF_PERIOD) begin
                    clk_div <= 6'd0;

                    if (!sample_phase) begin
                        // Phase 0: CB2 already has data, raise CB1 (rising → VIA shifts)
                        cuda_cb1  <= 1'b1;
                        bit_count <= bit_count + 1'd1;
                        sample_phase <= 1'b1;
                    end else begin
                        // Phase 1: Lower CB1, drive next data bit
                        cuda_cb1 <= 1'b0;
                        sample_phase <= 1'b0;

                        if (bit_count >= 4'd8) begin
                            // All 8 bits sent
                            if (send_count < send_length)
                                send_count <= send_count + 1'd1;
                            state <= ST_SEND_DONE;
                            wait_counter <= 16'd0;
`ifdef SIMULATION
                            if (send_count < send_length)
                                $display("EGRET_BEH: SEND byte[%0d] = 0x%02x complete",
                                         send_count, send_buf[send_count]);
                            else
                                $display("EGRET_BEH: SEND dummy byte complete (waiting for TIP deassert)");
`endif
                        end else begin
                            // Drive next bit on CB2
                            shift_data <= {shift_data[6:0], 1'b0};
                            cuda_cb2   <= shift_data[6]; // Next bit (was [6] before shift)
                        end
                    end
                end
            end

            // ==== SEND_DONE: byte sent, wait for host to read SR and toggle TACK ====
            ST_SEND_DONE: begin
                wait_counter <= wait_counter + 1'd1;
                cuda_cb1 <= 1'b0;

                if (send_count >= send_length) begin
                    // All bytes sent — deassert TREQ and keep clocking CB1
                    // until host sees TREQ=0 (in its ORB check) and deasserts TIP
                    treq_reg <= 1'b0;
                    if (!tip) begin
                        // Host deasserted TIP — we're done
                        state <= ST_FINISH;
                        wait_counter <= 16'd0;
`ifdef SIMULATION
                        $display("EGRET_BEH: Host deasserted TIP after all bytes sent");
`endif
                    end else begin
                        // Keep clocking dummy CB1 edges so host gets IFR[2]
                        // and can read ORB to see TREQ=0
                        state        <= ST_SEND_CLOCK;
                        clk_div      <= 6'd0;
                        bit_count    <= 4'd0;
                        sample_phase <= 1'b0;
                        shift_data   <= 8'h00;
                        cuda_cb2     <= 1'b0;
                        cuda_cb2_oe  <= 1'b1;
                    end
                end else begin
                    // More bytes to send — wait for host to read SR (triggers next exchange)
`ifdef SIMULATION
                    if (wait_counter == 16'd1)
                        $display("EGRET_BEH: SEND_DONE waiting for SR read (sent %0d/%0d) tip=%b",
                                 send_count, send_length, tip);
`endif
                    if (via_sr_read && !sr_read_prev) begin
                        // Host read SR, prepare next byte
                        state       <= ST_SEND_CLOCK;
                        clk_div     <= 6'd0;
                        bit_count   <= 4'd0;
                        sample_phase <= 1'b0;
                        shift_data  <= send_buf[send_count];
                        cuda_cb2    <= send_buf[send_count][7];
                        cuda_cb2_oe <= 1'b1;
`ifdef SIMULATION
                        $display("EGRET_BEH: Sending byte[%0d] = 0x%02x", send_count, send_buf[send_count]);
`endif
                    end else if (!tip) begin
                        // Host aborted — deassert TREQ and finish
                        treq_reg <= 1'b0;
                        state    <= ST_FINISH;
                        wait_counter <= 16'd0;
`ifdef SIMULATION
                        $display("EGRET_BEH: Host deasserted TIP mid-send (sent %0d/%0d)", send_count, send_length);
`endif
                    end else if (wait_counter >= 16'd50000) begin
                        treq_reg <= 1'b0;
                        state    <= ST_FINISH;
                        wait_counter <= 16'd0;
                    end
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
