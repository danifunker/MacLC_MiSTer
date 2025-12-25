///////////////////////////////////////////////////////////////////////////////
// Title      : VIA 6522 with Integrated RTC for Mac LC
///////////////////////////////////////////////////////////////////////////////
// Author     : Gideon Zweijtzer  <gideon.zweijtzer@gmail.com>
//              RTC Integration: Dani Church
///////////////////////////////////////////////////////////////////////////////
// Description: VIA 6522 with integrated Apple 343-0042-B RTC support
//              RTC connects to Port B[2:0]:
//              - PB0: RTC CE (chip enable, active low)
//              - PB1: RTC CLK (serial clock)
//              - PB2: RTC DATA (bidirectional)
///////////////////////////////////////////////////////////////////////////////

module via6522 (
    input  wire        clock,
    input  wire        rising,
    input  wire        falling,
    input  wire        reset,
    
    input  wire [3:0]  addr,
    input  wire        wen,
    input  wire        ren,
 
    input  wire [7:0]  data_in,
    output reg  [7:0]  data_out,

    output reg         phi2_ref,

    // pio
    output wire [7:0]  port_a_o,
    output wire [7:0]  port_a_t,
    input  wire [7:0]  port_a_i,
    
    output wire [7:0]  port_b_o,
    output wire [7:0]  port_b_t,
    input  wire [7:0]  port_b_i,

    // handshake pins
    
    input  wire        ca1_i,

    output wire        ca2_o,
    input  wire        ca2_i,
    output wire        ca2_t,
    
    output wire        cb1_o,
    input  wire        cb1_i,
    output wire        cb1_t,
    
  
    output wire        cb2_o,
    input  wire        cb2_i,
    output wire        cb2_t,

    output wire        irq,

    // Shift register status (for CUDA interface)
    output wire        sr_out_active,  // Shift register is actively shifting
    output wire        sr_out_dir,     // Shift direction: 0=in, 1=out
    output wire        sr_ext_clk,     // Using external clock (CB1)

    // RTC interface
    input  wire [32:0] rtc_timestamp   // Unix timestamp for RTC initialization
);
    localparam [15:0] latch_reset_pattern = 16'h5550;

    // PIO signals (replaces record type)
    reg [7:0] pio_i_pra  = 8'h00;
    reg [7:0] pio_i_ddra = 8'h00;
    reg [7:0] pio_i_prb  = 8'h00;
    reg [7:0] pio_i_ddrb = 8'h00;
    reg [7:0] port_a_c = 8'h00;
    reg [7:0] port_b_c = 8'h00;
    
    reg [6:0] irq_mask   = 7'h00;
    reg [6:0] irq_flags  = 7'h00;
    reg [6:0] irq_events = 7'h00;
    reg       irq_out;
    reg [15:0] timer_a_latch = latch_reset_pattern;
    reg [15:0] timer_b_latch = latch_reset_pattern;
    reg [15:0] timer_a_count = latch_reset_pattern;
    reg [15:0] timer_b_count = latch_reset_pattern;
    reg        timer_a_out;
    reg        timer_b_tick;
    reg [7:0] acr = 8'h00;
    reg [7:0] pcr = 8'h00;
    reg [7:0] shift_reg = 8'h00;
    reg       serport_en;
    reg       ser_cb2_o;
    reg       hs_cb2_o;
    reg       cb1_t_int;
    reg       cb1_o_int;
    reg       cb2_t_int;
    reg       cb2_o_int;

    // Aliases for irq_events
    wire ca2_event     = irq_events[0];
    wire ca1_event     = irq_events[1];
    
    wire serial_event;  
    wire cb2_event     = irq_events[3];
    wire cb1_event     = irq_events[4];
    wire timer_b_event;
    wire timer_a_event;

    // Aliases for irq_flags (for readability only - not driven)
    // wire ca2_flag     = irq_flags[0];
    // wire ca1_flag     = irq_flags[1];
    // wire serial_flag  = irq_flags[2];
    // wire cb2_flag     = irq_flags[3];
    // wire cb1_flag     = irq_flags[4];
    // wire timer_b_flag = irq_flags[5];
    // wire timer_a_flag = irq_flags[6];

    // Aliases for ACR bits
    wire       tmr_a_output_en       = acr[7];
    wire       tmr_a_freerun         = acr[6];
    wire       tmr_b_count_mode      = acr[5];
    wire       shift_dir             = acr[4];
    wire [1:0] shift_clk_sel         = acr[3:2];
    wire [2:0] shift_mode_control    = acr[4:2];
    wire       pb_latch_en           = acr[1];
    wire       pa_latch_en           = acr[0];
    // Aliases for PCR bits
    wire       cb2_is_output         = pcr[7];
    wire       cb2_edge_select       = pcr[6];
    wire       cb2_no_irq_clr        = pcr[5];
    wire [1:0] cb2_out_mode          = pcr[6:5];
    wire       cb1_edge_select       = pcr[4];
    wire       ca2_is_output         = pcr[3];
    wire       ca2_edge_select       = pcr[2];
    wire       ca2_no_irq_clr        = pcr[1];
    wire [1:0] ca2_out_mode          = pcr[2:1];
    wire       ca1_edge_select       = pcr[0];
    reg [7:0] ira = 8'h00;
    reg [7:0] irb = 8'h00;

    reg write_t1c_l;
    reg write_t1c_h;
    reg write_t2c_h;

    reg ca1_c = 1'b0;
    reg ca2_c = 1'b0;
    reg cb1_c = 1'b0;
    reg cb2_c = 1'b0;
    reg ca1_d = 1'b0;
    reg ca2_d = 1'b0;
    reg cb1_d = 1'b0;
    reg cb2_d = 1'b0;
    
    reg ca2_handshake_o = 1'b1;
    reg ca2_pulse_o = 1'b1;
    reg cb2_handshake_o = 1'b1;
    reg cb2_pulse_o = 1'b1;
    reg shift_active;

    //=========================================================================
    // RTC INTEGRATION
    //=========================================================================
    
    // RTC signals
    wire       rtc_ce_n   = pio_i_prb[0];  // Active low
    wire       rtc_clk    = pio_i_prb[1];
    wire       rtc_data_o = pio_i_prb[2];  // VIA output to RTC
    wire       rtc_data_i;                 // RTC output to VIA
    
    // RTC state machine states
    localparam [1:0] 
        RTC_STATE_NORMAL    = 2'b00,
        RTC_STATE_WRITE     = 2'b01,
        RTC_STATE_XPCOMMAND = 2'b10,
        RTC_STATE_XPWRITE   = 2'b11;

    // RTC internal signals
    reg   [2:0] rtc_bit_cnt;
    reg         rtc_ck_d;
    reg   [7:0] rtc_din;
    reg   [7:0] rtc_cmd;
    reg   [7:0] rtc_dout;
    reg         rtc_cmd_mode;
    reg         rtc_receiving;
    reg   [1:0] rtc_state;
    
    // Time keeping
    reg  [31:0] rtc_secs;
    reg  [24:0] rtc_clocktoseconds;
    
    // PRAM - 256 bytes for 343-0042-B
    reg   [7:0] rtc_pram[256];
    
    // Extended PRAM addressing
    reg   [7:0] rtc_xpaddr;
    
    // Write protect and test mode
    reg         rtc_write_protect;
    reg         rtc_test_mode;
    
    // CS debounce for Mac LC ROM behavior
    reg   [7:0] rtc_cs_deassert_cnt;
    
    // RTC data output register
    reg         rtc_data_out_reg;
    assign      rtc_data_i = rtc_data_out_reg;
    
    // Initialize PRAM with Mac LC defaults
    integer i;
    initial begin
        rtc_state = RTC_STATE_NORMAL;
        rtc_write_protect = 1'b0;
        rtc_test_mode = 1'b0;
        rtc_data_out_reg = 1'b1;
        rtc_ck_d = 1'b1;
        rtc_dout = 8'hFF;
        
        for (i = 0; i < 256; i = i + 1) begin
            rtc_pram[i] = 8'h00;
        end
        
        // Mac LC specific defaults
        rtc_pram[8'h00] = 8'hA8;
        rtc_pram[8'h01] = 8'h00;
        rtc_pram[8'h02] = 8'h00;
        rtc_pram[8'h03] = 8'h22;
        rtc_pram[8'h04] = 8'hCC;
        rtc_pram[8'h05] = 8'h0A;
        rtc_pram[8'h06] = 8'hCC;
        rtc_pram[8'h07] = 8'h0A;
        rtc_pram[8'h0D] = 8'h02;
        rtc_pram[8'h0E] = 8'h63;
        rtc_pram[8'h10] = 8'h03;
        rtc_pram[8'h11] = 8'h88;
        rtc_pram[8'h13] = 8'h6C;
    end
    
    initial rtc_secs = 0;
    
    // RTC Logic
    always @(posedge clock) begin
        if (reset) begin
            rtc_bit_cnt <= 0;
            rtc_receiving <= 1;
            rtc_cmd_mode <= 1;
            rtc_data_out_reg <= 1;
            rtc_cs_deassert_cnt <= 0;
            rtc_state <= RTC_STATE_NORMAL;
            rtc_write_protect <= 0;
            rtc_test_mode <= 0;
        end 
        else begin
            // Initialize timestamp on first boot
            if (rtc_secs == 0)
                rtc_secs <= rtc_timestamp[31:0] + 32'd2082844800; // Unix epoch to Mac epoch

            // Increment seconds counter (assume 32MHz clock for now)
            // Adjust divisor based on your actual system clock
            rtc_clocktoseconds <= rtc_clocktoseconds + 1'd1;
            if (rtc_clocktoseconds == 25'd31999999) begin  // 32MHz
                rtc_clocktoseconds <= 0;
                if (!rtc_test_mode)
                    rtc_secs <= rtc_secs + 1;
            end

            // Track clock transitions
            rtc_ck_d <= rtc_clk;

            // CS debounce logic
            if (rtc_ce_n) begin
                rtc_cs_deassert_cnt <= rtc_cs_deassert_cnt + 1'd1;
                if (rtc_cs_deassert_cnt >= 8'd100) begin
                    rtc_bit_cnt <= 0;
                    rtc_receiving <= 1;
                    rtc_cmd_mode <= 1;
                    rtc_state <= RTC_STATE_NORMAL;
                end
            end
            else begin
                rtc_cs_deassert_cnt <= 8'd0;
            end

            // Process serial communication when chip is selected
            if (rtc_cs_deassert_cnt < 8'd10) begin
                // Transmit on falling edge of clock
                if (rtc_ck_d & ~rtc_clk & !rtc_receiving)
                    rtc_data_out_reg <= rtc_dout[7 - rtc_bit_cnt];
                
                // Receive on rising edge of clock
                if (~rtc_ck_d & rtc_clk) begin
                    rtc_bit_cnt <= rtc_bit_cnt + 1'd1;
                    if (rtc_receiving)
                        rtc_din <= {rtc_din[6:0], rtc_data_o};

                    // Process complete byte
                    if (rtc_bit_cnt == 7) begin
                        rtc_process_byte({rtc_din[6:0], rtc_data_o});
                    end
                end
            end
        end
    end
    
    // Task to process received RTC byte based on current state
    task rtc_process_byte;
        input [7:0] data_byte;
        reg [4:0] reg_addr;
        begin
            reg_addr = 5'd0;  // Initialize to prevent latch
            case (rtc_state)
                RTC_STATE_NORMAL: begin
                    if (rtc_cmd_mode) begin
                        // Command byte received
                        rtc_cmd <= data_byte;
                        rtc_cmd_mode <= 0;
                        
                        // Check for extended command
                        if ((data_byte[6:3] == 4'b0111)) begin
                            // Extended PRAM command (0x38-0x3F)
                            rtc_state <= RTC_STATE_XPCOMMAND;
                            rtc_receiving <= 1;
                            rtc_bit_cnt <= 0;
                        end
                        else if (data_byte[7]) begin
                            // Read command
                            rtc_receiving <= 0;
                            rtc_state <= RTC_STATE_NORMAL;
                            reg_addr = data_byte[6:2];
                            
                            case (1'b1)
                                (reg_addr < 5'd4):   // Seconds register (0-3)
                                    rtc_dout <= rtc_secs[reg_addr[1:0] * 8 +: 8];
                                (reg_addr < 5'd8):   // Seconds register aliases (4-7)
                                    rtc_dout <= rtc_secs[reg_addr[1:0] * 8 +: 8];
                                (reg_addr < 5'd12):  // PRAM 0x08-0x0B
                                    rtc_dout <= rtc_pram[reg_addr];
                                (reg_addr >= 5'd16): // PRAM 0x10-0x1F
                                    rtc_dout <= rtc_pram[reg_addr];
                                default:
                                    rtc_dout <= 8'h00;
                            endcase
                        end
                        else begin
                            // Write command
                            rtc_state <= RTC_STATE_WRITE;
                            rtc_receiving <= 1;
                            rtc_bit_cnt <= 0;
                        end
                    end
                end
                
                RTC_STATE_WRITE: begin
                    // Data byte for write command received
                    rtc_state <= RTC_STATE_NORMAL;
                    rtc_cmd_mode <= 1;
                    rtc_receiving <= 1;
                    rtc_bit_cnt <= 0;
                    
                    reg_addr = rtc_cmd[6:2];
                    
                    // Check write protect (except for write-protect register itself)
                    if (!rtc_write_protect || reg_addr == 5'd13) begin
                        case (1'b1)
                            (reg_addr < 5'd4):   // Seconds register (0-3)
                                rtc_secs[reg_addr[1:0] * 8 +: 8] <= data_byte;
                            (reg_addr < 5'd8):   // Seconds register aliases (4-7)
                                rtc_secs[reg_addr[1:0] * 8 +: 8] <= data_byte;
                            (reg_addr < 5'd12):  // PRAM 0x08-0x0B
                                rtc_pram[reg_addr] <= data_byte;
                            (reg_addr == 5'd12): // Test register
                                rtc_test_mode <= data_byte[7];
                            (reg_addr == 5'd13): // Write-protect register
                                rtc_write_protect <= data_byte[7];
                            (reg_addr >= 5'd16): // PRAM 0x10-0x1F
                                rtc_pram[reg_addr] <= data_byte;
                            default: ;
                        endcase
                    end
                end
                
                RTC_STATE_XPCOMMAND: begin
                    // Extended command address byte received
                    rtc_xpaddr <= {rtc_cmd[2:0], data_byte[6:2]};
                    
                    if (rtc_cmd[7]) begin
                        // Extended read
                        rtc_state <= RTC_STATE_NORMAL;
                        rtc_cmd_mode <= 1;
                        rtc_receiving <= 0;
                        rtc_dout <= rtc_pram[{rtc_cmd[2:0], data_byte[6:2]}];
                    end
                    else begin
                        // Extended write - wait for data
                        rtc_state <= RTC_STATE_XPWRITE;
                        rtc_receiving <= 1;
                        rtc_bit_cnt <= 0;
                    end
                end
                
                RTC_STATE_XPWRITE: begin
                    // Extended PRAM write data received
                    if (!rtc_write_protect)
                        rtc_pram[rtc_xpaddr] <= data_byte;
                    rtc_state <= RTC_STATE_NORMAL;
                    rtc_cmd_mode <= 1;
                    rtc_receiving <= 1;
                    rtc_bit_cnt <= 0;
                end
            endcase
        end
    endtask
    
    //=========================================================================
    // END RTC INTEGRATION
    //=========================================================================

    // Assignments
    assign irq = irq_out;
    always @(*) begin
        write_t1c_l = ((addr == 4'h4 || addr == 4'h6) && wen && falling);
        write_t1c_h = (addr == 4'h5 && wen && falling);
        write_t2c_h = (addr == 4'h9 && wen && falling);
    end

    always @(*) begin
        irq_events[1] = (ca1_c ^ ca1_d) & (ca1_d ^ ca1_edge_select);
        irq_events[0] = (ca2_c ^ ca2_d) & (ca2_d ^ ca2_edge_select);
        irq_events[4] = (cb1_c ^ cb1_d) & (cb1_d ^ cb1_edge_select);
        irq_events[3] = (cb2_c ^ cb2_d) & (cb2_d ^ cb2_edge_select);
        
        irq_events[2] = serial_event;
        irq_events[5] = timer_b_event;
        irq_events[6] = timer_a_event;
    end

    assign ca2_t = ca2_is_output;
    always @(*) begin
        cb2_t_int = serport_en ? shift_dir : cb2_is_output;
        cb2_o_int = serport_en ? ser_cb2_o : hs_cb2_o;
    end

    assign cb1_t = cb1_t_int;
    assign cb1_o = cb1_o_int;
    assign cb2_t = cb2_t_int;
    assign cb2_o = cb2_o_int;

    assign ca2_o = (ca2_out_mode == 2'b00) ?
                   ca2_handshake_o :
                   (ca2_out_mode == 2'b01) ?
                   ca2_pulse_o :
                   (ca2_out_mode == 2'b10) ?
                   1'b0 : 1'b1;
        
    always @(*) begin
        hs_cb2_o = (cb2_out_mode == 2'b00) ?
                   cb2_handshake_o :
                   (cb2_out_mode == 2'b01) ?
                   cb2_pulse_o :
                   (cb2_out_mode == 2'b10) ?
                   1'b0 : 1'b1;
    end

    always @(*) begin
        if ((irq_flags & irq_mask) == 7'h00) begin
            irq_out = 1'b0;
        end else begin
            irq_out = 1'b1;
        end
    end

    always @(posedge clock) begin
        if (rising) begin
            phi2_ref <= 1'b1;
        end else if (falling) begin
            phi2_ref <= 1'b0;
        end
    end

    always @(posedge clock) begin
        // CA1/CA2/CB1/CB2 edge detect flipflops
        ca1_c <= ca1_i;
        ca2_c <= ca2_i;
        if (cb1_t_int == 1'b0) begin
            cb1_c <= cb1_i;
        end else begin
            cb1_c <= cb1_o_int;
        end
        if (cb2_t_int == 1'b0) begin
            cb2_c <= cb2_i;
        end else begin
            cb2_c <= cb2_o_int;
        end

        ca1_d <= ca1_c;
        ca2_d <= ca2_c;
        cb1_d <= cb1_c;
        cb2_d <= cb2_c;
        // input registers
        port_a_c <= port_a_i;
        
        // Modified port_b_c to include RTC data input
        // When PB2 is input (DDRB[2]=0), read from RTC
        port_b_c[7:3] <= port_b_i[7:3];
        port_b_c[2] <= pio_i_ddrb[2] ? port_b_i[2] : rtc_data_i;
        port_b_c[1:0] <= port_b_i[1:0];
        
        // input latch emulation
        if (pa_latch_en == 1'b0 || ca1_event == 1'b1) begin
            ira <= port_a_c;
        end
        
        if (pb_latch_en == 1'b0 || cb1_event == 1'b1) begin
            irb <= port_b_c;
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            irq_flags[1:0] <= 2'b00;
        end else begin
            if (rising == 1'b1) begin
                if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h1) begin
                    irq_flags[1] <= 1'b0;
                    if (ca2_is_output == 1'b0 && ca2_no_irq_clr == 1'b0) begin
                        irq_flags[0] <= 1'b0;
                    end
                end
            end
            if (ca1_event == 1'b1) begin
                irq_flags[1] <= 1'b1;
            end
            if (ca2_event == 1'b1) begin
                irq_flags[0] <= 1'b1;
            end
            // IFR write handling
            if (falling == 1'b1 && wen == 1'b1 && addr == 4'hD && data_in[7] == 1'b0) begin
                if (data_in[0]) irq_flags[0] <= 1'b0;
                if (data_in[1]) irq_flags[1] <= 1'b0;
            end
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            irq_flags[4:3] <= 2'b00;
        end else begin
            if (rising == 1'b1) begin
                if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h0) begin
                    irq_flags[4] <= 1'b0;
                    if (cb2_is_output == 1'b0 && cb2_no_irq_clr == 1'b0) begin
                        irq_flags[3] <= 1'b0;
                    end
                end
            end
            
            if (cb1_event == 1'b1) begin
                irq_flags[4] <= 1'b1;
            end
            if (cb2_event == 1'b1) begin
                irq_flags[3] <= 1'b1;
            end
            // IFR write handling
            if (falling == 1'b1 && wen == 1'b1 && addr == 4'hD && data_in[7] == 1'b0) begin
                if (data_in[3]) irq_flags[3] <= 1'b0;
                if (data_in[4]) irq_flags[4] <= 1'b0;
            end
        end
    end

    always @(posedge clock) begin
        if (rising == 1'b1) begin
            // Handshake CA2 is set high when reading port A
            if (ca2_out_mode == 2'b00) begin
                if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h1) begin
                    ca2_handshake_o <= 1'b1;
                end
            end
            
            // Pulse CA2 for 1 cycle when reading port A
            if (ca2_out_mode == 2'b01) begin
                if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h1) begin
                    ca2_pulse_o <= 1'b0;
                end else begin
                    ca2_pulse_o <= 1'b1;
                end
            end
        end
        
        if (ca1_event == 1'b1 && ca2_out_mode == 2'b00) begin
            ca2_handshake_o <= 1'b0;
        end
        if (reset == 1'b1) begin
            ca2_handshake_o <= 1'b1;
            ca2_pulse_o <= 1'b1;
        end
    end

    always @(posedge clock) begin
        if (rising == 1'b1) begin
            if (cb2_out_mode == 2'b00) begin
                if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h0) begin
                    cb2_handshake_o <= 1'b1;
                end
            end
            
            if (cb2_out_mode == 2'b01) begin
                if (wen == 1'b1 && addr == 4'h0) begin
                    cb2_pulse_o <= 1'b0;
                end else begin
                    cb2_pulse_o <= 1'b1;
                end
            end
        end
        
        if (cb1_event == 1'b1 && cb2_out_mode == 2'b00) begin
            cb2_handshake_o <= 1'b0;
        end
        if (reset == 1'b1) begin
            cb2_handshake_o <= 1'b1;
            cb2_pulse_o <= 1'b1;
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            irq_flags[6] <= 1'b0;
        end else begin
            if (rising == 1'b1 && (ren == 1'b1 || wen == 1'b1) && addr == 4'h4) begin
                irq_flags[6] <= 1'b0;
            end
            if (timer_a_event == 1'b1) begin
                irq_flags[6] <= 1'b1;
            end
            // IFR write handling
            if (falling == 1'b1 && wen == 1'b1 && addr == 4'hD && data_in[7] == 1'b0) begin
                if (data_in[6]) irq_flags[6] <= 1'b0;
            end
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            irq_flags[5] <= 1'b0;
        end else begin
            if (rising == 1'b1 && (ren == 1'b1 || wen == 1'b1) && addr == 4'h8) begin
                irq_flags[5] <= 1'b0;
            end
            if (timer_b_event == 1'b1) begin
                irq_flags[5] <= 1'b1;
            end
            // IFR write handling
            if (falling == 1'b1 && wen == 1'b1 && addr == 4'hD && data_in[7] == 1'b0) begin
                if (data_in[5]) irq_flags[5] <= 1'b0;
            end
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            irq_flags[2] <= 1'b0;
        end else begin
            if (serial_event == 1'b1) begin
                irq_flags[2] <= 1'b1;
            end
            if (rising == 1'b1 && (ren == 1'b1 || wen == 1'b1) && addr == 4'hA) begin
                irq_flags[2] <= 1'b0;
            end
            // IFR write handling
            if (falling == 1'b1 && wen == 1'b1 && addr == 4'hD && data_in[7] == 1'b0) begin
                if (data_in[2]) irq_flags[2] <= 1'b0;
            end
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            data_out <= 8'h00;
        end else if (ren == 1'b1) begin
            case (addr)
                4'h0: data_out <= (pio_i_ddrb & pio_i_prb) | (~pio_i_ddrb & irb);
                4'h1: data_out <= (pio_i_ddra & pio_i_pra) | (~pio_i_ddra & ira);
                4'h2: data_out <= pio_i_ddrb;
                4'h3: data_out <= pio_i_ddra;
                4'h4: data_out <= timer_a_count[7:0];
                4'h5: data_out <= timer_a_count[15:8];
                4'h6: data_out <= timer_a_latch[7:0];
                4'h7: data_out <= timer_a_latch[15:8];
                4'h8: data_out <= timer_b_count[7:0];
                4'h9: data_out <= timer_b_count[15:8];
                4'hA: data_out <= shift_reg;
                4'hB: data_out <= acr;
                4'hC: data_out <= pcr;
                4'hD: data_out <= {irq_out, irq_flags};
                4'hE: data_out <= {1'b0, irq_mask};
                4'hF: data_out <= (pio_i_ddra & pio_i_pra) | (~pio_i_ddra & ira);
                default: data_out <= 8'h00;
            endcase
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            pio_i_prb  <= 8'h00;
            pio_i_pra  <= 8'h00;
            pio_i_ddrb <= 8'h00;
            pio_i_ddra <= 8'h00;
        end else if (falling == 1'b1 && wen == 1'b1) begin
            case (addr)
                4'h0: pio_i_prb <= data_in;
                4'h1: pio_i_pra <= data_in;
                4'hF: pio_i_pra <= data_in;
                4'h2: pio_i_ddrb <= data_in;
                4'h3: pio_i_ddra <= data_in;
                default: ;
            endcase
        end
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            timer_a_latch <= latch_reset_pattern;
            timer_b_latch <= latch_reset_pattern;
            acr <= 8'h00;
            pcr <= 8'h00;
            irq_mask <= 7'h00;
        end else if (falling == 1'b1 && wen == 1'b1) begin
            case (addr)
                4'h4, 4'h6: timer_a_latch[7:0] <= data_in;
                4'h5: timer_a_latch[15:8] <= data_in;
                4'h7: timer_a_latch[15:8] <= data_in;
                4'h8: timer_b_latch[7:0] <= data_in;
                4'h9: timer_b_latch[15:8] <= data_in;
                4'hB: acr <= data_in;
                4'hC: pcr <= data_in;
                4'hE: begin
                    if (data_in[7] == 1'b1) begin
                        irq_mask <= irq_mask | data_in[6:0];
                    end else begin
                        irq_mask <= irq_mask & ~data_in[6:0];
                    end
                end
                default: ;
            endcase
        end
    end

    assign port_a_o = pio_i_pra;
    assign port_a_t = pio_i_ddra;
    assign port_b_o[6:0] = pio_i_prb[6:0];
    assign port_b_o[7] = tmr_a_output_en ? timer_a_out : pio_i_prb[7];
    assign port_b_t[6:0] = pio_i_ddrb[6:0];
    assign port_b_t[7] = pio_i_ddrb[7] | tmr_a_output_en;
    // Timer A
    reg        timer_a_reload = 1'b0;
    reg        timer_a_toggle = 1'b1;
    reg        timer_a_may_interrupt = 1'b0;
    always @(posedge clock) begin
        if (falling == 1'b1) begin
            // always count, or load
                
            if (timer_a_reload == 1'b1) begin
                timer_a_count <= timer_a_latch;
                if (write_t1c_l == 1'b1) begin
                    timer_a_count[7:0] <= data_in;
                end
                timer_a_reload <= 1'b0;
                timer_a_may_interrupt <= timer_a_may_interrupt & tmr_a_freerun;
            end else begin
                if (timer_a_count == 16'h0000) begin
                    // generate an event if we were triggered
                    timer_a_reload <= 1'b1;
                end
                // Timer continues to count in both free run and one shot.
                timer_a_count <= timer_a_count - 16'h0001;
            end
        end
        
        if (rising == 1'b1) begin
            if (timer_a_event == 1'b1 && tmr_a_output_en == 1'b1) begin
                timer_a_toggle <= ~timer_a_toggle;
            end
        end

        if (write_t1c_h == 1'b1) begin
            timer_a_may_interrupt <= 1'b1;
            timer_a_toggle <= ~tmr_a_output_en;
            timer_a_count <= {data_in, timer_a_latch[7:0]};
            timer_a_reload <= 1'b0;
        end

        if (reset == 1'b1) begin
            timer_a_may_interrupt <= 1'b0;
            timer_a_toggle <= 1'b1;
            timer_a_count <= latch_reset_pattern;
            timer_a_reload <= 1'b0;
        end
    end

    assign timer_a_out = timer_a_toggle;
    assign timer_a_event = rising & timer_a_reload & timer_a_may_interrupt;

    // Timer B
    reg        timer_b_reload_lo = 1'b0;
    reg        timer_b_oneshot_trig = 1'b0;
    reg        timer_b_timeout = 1'b0;
    reg        pb6_c = 1'b0;
    reg        pb6_d = 1'b0;
    always @(posedge clock) begin
        reg timer_b_decrement;
        
        timer_b_decrement = 1'b0;
        if (rising == 1'b1) begin
            pb6_c <= port_b_i[6];
            pb6_d <= pb6_c;
        end
                        
        if (falling == 1'b1) begin
            timer_b_timeout <= 1'b0;
            timer_b_tick <= 1'b0;

            if (tmr_b_count_mode == 1'b1) begin
                if (pb6_d == 1'b1 && pb6_c == 1'b0) begin
                    timer_b_decrement = 1'b1;
                end
            end else begin // one shot or used for shift register
                timer_b_decrement = 1'b1;
            end
                
            if (timer_b_decrement == 1'b1) begin
                if (timer_b_count == 16'h0000) begin
                    if (timer_b_oneshot_trig == 1'b1) begin
                        
                        timer_b_oneshot_trig <= 1'b0;
                        timer_b_timeout <= 1'b1;
                    end
                end
                if (timer_b_count[7:0] == 8'h00) begin
                    case (shift_mode_control)
                        3'b001, 3'b101, 3'b100: begin
          
                            timer_b_reload_lo <= 1'b1;
                            timer_b_tick <= 1'b1;
                        end
                        default: begin
                        end
                    endcase
                end
            
                timer_b_count <= timer_b_count - 16'h0001;
            end
            if (timer_b_reload_lo == 1'b1) begin
                timer_b_count[7:0] <= timer_b_latch[7:0];
                timer_b_reload_lo <= 1'b0;
            end
        end

        if (write_t2c_h == 1'b1) begin
            timer_b_count <= {data_in, timer_b_latch[7:0]};
            timer_b_oneshot_trig <= 1'b1;
        end

        if (reset == 1'b1) begin
            timer_b_count <= latch_reset_pattern;
            timer_b_reload_lo <= 1'b0;
            timer_b_oneshot_trig <= 1'b0;
        end
    end

    assign timer_b_event = rising & timer_b_timeout;
    // Serial port
    reg        trigger_serial;
    reg        shift_clock_d = 1'b1;
    reg        shift_clock = 1'b1;
    reg        shift_tick_r;
    reg        shift_tick_f;
    reg        shift_timer_tick;
    reg        ser_cb2_c = 1'b0;
    reg [2:0]  bit_cnt = 3'd0;
    reg        shift_pulse;

    always @(*) begin
        case (shift_clk_sel)
            2'b10: begin
                shift_pulse = 1'b1;
            end
                
            2'b00, 2'b01: begin
                shift_pulse = shift_timer_tick;
            end
            
            default: begin
                shift_pulse = shift_clock & ~shift_clock_d;
            end
        endcase

        if (shift_active == 1'b0) begin
            // Mode 0 still loads the shift register to external pulse (MMBEEB SD-Card interface uses this)
            if (shift_mode_control == 3'b000) begin
                shift_pulse = shift_clock & ~shift_clock_d;
            end else begin
                shift_pulse = 1'b0;
            end
        end
    end

    always @(posedge clock) begin
        ser_cb2_c <= cb2_i;
        if (rising == 1'b1) begin
            if (shift_active == 1'b0) begin
                if (shift_mode_control == 3'b000) begin
                    shift_clock <= cb1_i;
                end else begin
                    shift_clock <= 1'b1;
                end
            end else if (shift_clk_sel == 2'b11) begin
                shift_clock <= cb1_i;
            end else if (shift_pulse == 1'b1) begin
                shift_clock <= ~shift_clock;
            end

            shift_clock_d <= shift_clock;
        end

        if (falling == 1'b1) begin
            shift_timer_tick <= timer_b_tick;
        end

        if (reset == 1'b1) begin
            shift_clock <= 1'b1;
            shift_clock_d <= 1'b1;
        end
    end

    always @(*) begin
        cb1_t_int = (shift_clk_sel == 2'b11) ?
                    1'b0 : serport_en;
        cb1_o_int = shift_clock_d;
        ser_cb2_o = shift_reg[7];
    end

    always @(*) begin
        serport_en = shift_dir |
                     shift_clk_sel[1] | shift_clk_sel[0];
        trigger_serial = ((ren == 1'b1 || wen == 1'b1) && addr == 4'hA);
        shift_tick_r = ~shift_clock_d & shift_clock;
        shift_tick_f = shift_clock_d & ~shift_clock;
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            shift_reg <= 8'hFF;
        end else if (falling == 1'b1) begin
            if (wen == 1'b1 && addr == 4'hA) begin
                shift_reg <= data_in;
            end else if (shift_dir == 1'b1 && shift_tick_f == 1'b1) begin // output
                shift_reg <= {shift_reg[6:0], shift_reg[7]};
            end else if (shift_dir == 1'b0 && shift_tick_r == 1'b1) begin // input
                shift_reg <= {shift_reg[6:0], ser_cb2_c};
            end
        end
    end

    // tell people that we're ready!
    assign serial_event = shift_tick_r & ~shift_active & rising & serport_en;
    always @(posedge clock) begin
        if (falling == 1'b1) begin
            if (shift_active == 1'b0 && shift_mode_control != 3'b000) begin
                if (trigger_serial == 1'b1) begin
                    bit_cnt <= 3'd7;
                    shift_active <= 1'b1;
                end
            end else begin // we're active
                if (shift_clk_sel == 2'b00) begin
                    shift_active <= shift_dir;
                    // when '1' we're active, but for mode 000 we go inactive.
                end else if (shift_pulse == 1'b1 && shift_clock == 1'b1) begin
                    if (bit_cnt == 3'd0) begin
                        shift_active <= 1'b0;
                    end else begin
                        bit_cnt <= bit_cnt - 3'd1;
                    end
                end
            end
        end

        if (reset == 1'b1) begin
            shift_active <= 1'b0;
            bit_cnt <= 3'd0;
        end
    end

    // Shift register status outputs for CUDA interface
    assign sr_out_active = shift_active;
    assign sr_out_dir    = shift_dir;
    assign sr_ext_clk    = (shift_clk_sel == 2'b11);  // External clock mode (CB1)

endmodule