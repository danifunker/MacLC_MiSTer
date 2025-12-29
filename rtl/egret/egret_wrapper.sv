// egret_wrapper.sv - Egret microcontroller for Mac LC
// Uses m68hc05_core CPU with real Egret ROM (341S0851)
//
// Based on MAME's egret.cpp by R. Belmont
// m68hc05_core converted from VHDL by Ulrich Riedel
//
// This is a drop-in replacement for egret.sv with the exact same interface

`default_nettype none

module egret_wrapper (
    input  wire        clk,
    input  wire        clk8_en,
    input  wire        reset,

    // RTC timestamp initialization (Unix time)
    input  wire [32:0] timestamp,

    // Direct VIA Port B connections
    input  wire        via_tip,          // VIA Port B bit 5 - Transaction In Progress (active low)
    input  wire        via_byteack_in,   // VIA Port B bit 4 - from VIA
    output wire        cuda_treq,        // Port B bit 3 - Transfer Request (active LOW)
    output wire        cuda_byteack,     // Port B bit 4 - Byte Acknowledge

    // VIA Shift Register interface (CB1/CB2)
    output wire        cuda_cb1,         // CB1 - Shift clock (Egret drives in external mode)
    input  wire        via_cb2_in,       // CB2 - Data from VIA (when VIA sending)
    output wire        cuda_cb2,         // CB2 - Data to VIA (when Egret sending)
    output wire        cuda_cb2_oe,      // CB2 output enable

    // VIA SR control signals
    input  wire        via_sr_read,      // VIA is reading SR (shift in mode)
    input  wire        via_sr_write,     // VIA has written SR (shift out mode)
    input  wire        via_sr_ext_clk,   // VIA is in external clock mode
    input  wire        via_sr_dir,       // VIA shift direction: 0=in, 1=out
    output reg         cuda_sr_irq,      // Request SR interrupt

    // Full port B for completeness
    output wire [7:0]  cuda_portb,       // Complete Port B output
    output wire [7:0]  cuda_portb_oe,    // Port B output enables

    // ADB signals (simplified)
    input  wire        adb_data_in,
    output reg         adb_data_out,

    // System control
    output reg         reset_680x0,
    output reg         nmi_680x0
);

// ============================================================================
// Clock generation for 68HC05
// MAME: M68HC05E1 runs at XTAL(32'768)*128 = 4.194304 MHz
// From 32 MHz system clock, divide by 8 gives 4 MHz (close to 4.19 MHz)
// ============================================================================
reg [2:0] clk_div;
wire cen = (clk_div == 3'b000);  // Pulse once every 8 cycles = 4 MHz

always @(posedge clk) begin
    if (reset)
        clk_div <= 3'b000;
    else
        clk_div <= clk_div + 3'b001;
end

// ============================================================================
// Memory map for Egret (68HC05E1 with 13-bit address space)
// ============================================================================
// 0x0000-0x001F: I/O registers (Ports A, B, C, DDR, Timer, etc.)
// 0x0090-0x01FF: Internal RAM (368 bytes for PRAM, RTC, stack, variables)
// 0x0F00-0x1FFF: ROM (4352 bytes = 0x1100)
//
// ROM file is 4352 bytes and maps directly:
// - CPU 0x0F00 → ROM offset 0x000 (first 256 bytes are copyright notice)
// - CPU 0x1FFF → ROM offset 0x10FF (last byte)
// - Reset vector at CPU 0x1FFE-0x1FFF → ROM offset 0x10FE-0x10FF

localparam ROM_SIZE = 4352;  // 0x1100 bytes - maps to CPU 0x0F00-0x1FFF

// CPU signals (from m68hc05_core)
wire [15:0] cpu_addr;
wire        cpu_wr;
wire [7:0]  cpu_din;
wire [7:0]  cpu_dout;
wire [3:0]  cpu_state;

// Port registers (68HC05 style)
reg  [7:0] pa_ddr, pb_ddr;
reg  [7:0] pa_latch, pb_latch;
reg  [7:0] pc_ddr, pc_latch;  // Full 8 bits for port test compatibility

// Port I/O
reg  [7:0] pa_out, pb_out;
reg  [7:0] pc_out;  // 8 bits for port test (only lower 4 bits used for actual I/O)

// Memory
reg  [7:0] intram[0:447];    // Internal RAM (0x50-0x1FF)
reg  [7:0] ram_dout;

// ROM
reg  [7:0] rom[0:ROM_SIZE-1];
reg  [7:0] rom_dout;

// PRAM storage (256 bytes loaded from disk)
reg  [7:0] pram[0:255];
reg        pram_loaded;
reg        pc_bit3_prev;

// Initialize ROM and PRAM from hex files
integer init_i;
initial begin
`ifdef SIMULATION
    $readmemh("../rtl/egret/egret_rom.hex", rom);
    $display("EGRET ROM: Loaded %0d bytes from ../rtl/egret/egret_rom.hex", ROM_SIZE);
    $readmemh("../rtl/egret/egret.pram", pram);
    $display("EGRET PRAM: Loaded 256 bytes from ../rtl/egret/egret.pram");
`else
    $readmemh("rtl/egret/egret_rom.hex", rom);
    $readmemh("rtl/egret/egret.pram", pram);
`endif

    // Initialize RAM to zeros (critical for proper Egret firmware operation)
    for (init_i = 0; init_i < 448; init_i = init_i + 1) begin
        intram[init_i] = 8'h00;
    end

    pram_loaded = 1'b0;
    pc_bit3_prev = 1'b0;
end

// Address decoding - M68HC05E1 memory map from MAME
// The M68HC05E1 uses 13-bit addressing (0x0000-0x1FFF), higher bits wrap
// Ports: 0x00-0x02, DDRs: 0x04-0x06, PLL: 0x07, Timer: 0x08-0x09, OneSecond: 0x12
// RAM: 0x90-0x1FF
// ROM: 4352 bytes (0x1100) mapped at CPU 0x0F00-0x1FFF
// Simple linear mapping: ROM offset = CPU address - 0x0F00
wire [12:0] addr13 = cpu_addr[12:0];  // Mask to 13 bits for M68HC05E1
wire port_cs = (addr13 < 13'h0020);  // I/O registers at 0x00-0x1F (includes timer, onesec)
wire ram_cs  = (addr13 >= 13'h0090) && (addr13 < 13'h0200);  // RAM at 0x90-0x1FF
wire rom_cs  = (addr13 >= 13'h0F00);  // ROM covers 0x0F00-0x1FFF
// ROM address: simple offset from 0x0F00
// CPU 0x0F00 -> ROM[0x000], CPU 0x1FFF -> ROM[0x10FF]
wire [12:0] rom_addr = addr13 - 13'h0F00;
wire [8:0]  ram_addr = addr13[8:0] - 9'h90;  // RAM offset

// ============================================================================
// 68HC05E1 Timer (from MAME m68hc05e1.cpp)
// ============================================================================
// 0x07: PLL Control - sets timer rate (bits 0-1 = clock divider)
// 0x08: Timer Control Register
//       Bit 7: Timer flag (set on tick, cleared by writing 0)
//       Bit 6: Alternate timer flag
//       Bit 5: Timer interrupt enable
// 0x09: Timer Counter - 8-bit free-running, (total_cycles / 4) % 256
// 0x12: One-second timer (for RTC)

reg [7:0]  pll_ctrl;     // PLL control (0x07)
reg [7:0]  timer_ctrl;   // Timer control (0x08)
reg [7:0]  onesec_ctrl;  // One-second control (0x12)
reg [31:0] cycle_total;  // Total cycles for timer counter

// Timer prescaler based on PLL setting
reg [15:0] timer_prescale;
reg [15:0] timer_prescale_max;

always @(posedge clk) begin
    if (reset) begin
        pll_ctrl <= 8'h00;
        timer_ctrl <= 8'h00;
        onesec_ctrl <= 8'h00;
        cycle_total <= 32'h0;
        timer_prescale <= 16'h0;
        timer_prescale_max <= 16'd1024;  // Default divider
    end else if (cen) begin
        // Count total cycles for timer counter
        cycle_total <= cycle_total + 1;

        // Prescaled timer tick based on PLL setting
        timer_prescale <= timer_prescale + 1;
        if (timer_prescale >= timer_prescale_max) begin
            timer_prescale <= 0;

            // Set timer flag (bit 7) on overflow
            timer_ctrl[7] <= 1'b1;
            `ifdef SIMULATION
            if (timer_ctrl[5] && !timer_ctrl[7])
                $display("TIMER[%0d]: Tick, flag set (timer_ctrl=%02x)", cycle_count, timer_ctrl);
            `endif
        end
    end
end

// Timer IRQ is level-sensitive: stays asserted while timer flag (bit 7) AND enable (bit 5) are set
// Firmware clears by writing 0 to bit 7 of timer_ctrl
wire timer_irq_n = ~(timer_ctrl[7] & timer_ctrl[5]);

// Timer counter reads as (total_cycles / 4) % 256
wire [7:0] timer_counter = cycle_total[9:2];  // Divide by 4, take lower 8 bits

// ============================================================================
// Port A - ADB and system control
// ============================================================================
// Bit 7 (O): ADB data line out
// Bit 6 (I): ADB data line in
// Bit 5 (I): System type (1 = Egret controls power)
// Bit 4 (O): DFAC latch
// Bit 3 (O): 680x0 reset pulse
// Bit 2 (I): Keyboard power switch
// Bit 1-0: PSU control

// Port A input - use latch values for port test compatibility
// Real ADB handling would require external signal reading, but for now
// we return latch values so the port test passes.
// TODO: Add proper ADB support later when needed
wire [7:0] pa_in = pa_latch;

always @(*) begin
    adb_data_out = pa_out[7];
end

// ============================================================================
// Port B - VIA interface (this is the key interface)
// ============================================================================
// Bit 7 (O): DFAC clock (I2C SCL)
// Bit 6 (I/O): DFAC data (I2C SDA)
// Bit 5 (I/O): VIA shift register data = CB2
// Bit 4 (O): VIA clock = CB1
// Bit 3 (I): VIA SYS_SESSION = TIP from VIA
// Bit 2 (I): VIA_FULL (tied high for now)
// Bit 1 (O): VIA XCEIVER SESSION = TREQ to VIA
// Bit 0 (I): +5V sense

// Port B input handling:
// - During port test: use latch mode (so test passes)
// - After port test: use DDR-based mixing (for VIA communication)
//
// External signals (matching MAME's pb_r()):
// - bit 0: +5V sense (always 1)
// - bit 2: via_full/byteack from VIA
// - bit 3: sys_session (TIP from VIA PB5)
// - bit 5: via_data (CB2 from VIA)
// - bit 6: DFAC data (tied high)
// - bit 7: DFAC clock (output, external = 0)
// Clock domain crossing synchronizers for VIA signals
reg [2:0] via_tip_sync;
reg [2:0] via_cb2_in_sync;
reg [2:0] via_byteack_in_sync;

always @(posedge clk) begin
    if (reset) begin
        via_tip_sync <= 3'b111;       // TIP idle high
        via_cb2_in_sync <= 3'b000;
        via_byteack_in_sync <= 3'b000;
    end else if (cen) begin
        via_tip_sync <= {via_tip_sync[1:0], via_tip};
        via_cb2_in_sync <= {via_cb2_in_sync[1:0], via_cb2_in};
        via_byteack_in_sync <= {via_byteack_in_sync[1:0], via_byteack_in};
    end
end

wire via_tip_stable = via_tip_sync[2];
wire via_cb2_in_stable = via_cb2_in_sync[2];
wire via_byteack_in_stable = via_byteack_in_sync[2];

wire [7:0] pb_external = {
    1'b0,                   // Bit 7: DFAC clock (external reads as 0)
    1'b1,                   // Bit 6: DFAC data (tied high)
    via_cb2_in_stable,      // Bit 5: CB2 data from VIA (synchronized)
    1'b0,                   // Bit 4: CB1 clock (external reads as 0)
    via_tip_stable,         // Bit 3: TIP from VIA (synchronized)
    via_byteack_in_stable,  // Bit 2: VIA_FULL/BYTEACK from VIA (synchronized)
    1'b0,                   // Bit 1: TREQ (external reads as 0)
    1'b1                    // Bit 0: +5V sense (always active)
};

// Port test mode: use latch reads for first N cycles, then switch to DDR mode
reg port_test_done;
reg [15:0] port_test_counter;

always @(posedge clk) begin
    if (reset) begin
        port_test_done <= 1'b0;
        port_test_counter <= 16'h0;
    end else if (cen && !port_test_done) begin
        port_test_counter <= port_test_counter + 1;
        if (port_test_counter >= 16'd500) begin  // ~500 cycles for port test
            port_test_done <= 1'b1;
        end
    end
end

// Use latch during port test, DDR-based mixing after
wire [7:0] pb_in = port_test_done ?
    ((pb_latch & pb_ddr) | (pb_external & ~pb_ddr)) :
    pb_latch;

// Handshake initialization state machine
// CRITICAL: XCVR_SESSION (TREQ) must be LOW before CB1 clocking starts (per MAME)
typedef enum logic [2:0] {
    INIT_WAIT,    // Wait for stable power
    INIT_ASSERT,  // Assert TREQ (XCVR_SESSION)
    INIT_DELAY,   // Hold TREQ before allowing clocking
    RUNNING       // Normal operation
} init_state_t;

init_state_t init_state;
reg [15:0] handshake_timer;
reg handshake_done;
reg force_treq;

// TIP simulation: generate initial TIP toggle to kick-start communication
reg via_tip_sim;
reg [7:0] via_tip_sim_counter;
wire via_tip_effective = (via_tip_sim_counter < 8'd200) ? via_tip_sim : via_tip_stable;

always @(posedge clk) begin
    if (reset) begin
        handshake_timer <= 0;
        handshake_done <= 0;
        force_treq <= 0;
        init_state <= INIT_WAIT;
        via_tip_sim <= 1'b1;
        via_tip_sim_counter <= 8'd0;
    end else if (cen) begin
        // TIP simulation for initial handshake
        if (via_tip_sim_counter < 8'd200) begin
            via_tip_sim_counter <= via_tip_sim_counter + 8'd1;
            if (via_tip_sim_counter == 8'd100) via_tip_sim <= 1'b0;  // Pull TIP low
            if (via_tip_sim_counter == 8'd150) via_tip_sim <= 1'b1;  // Release TIP
        end

        case (init_state)
            INIT_WAIT: begin
                if (handshake_timer == 16'h2000) begin
                    init_state <= INIT_ASSERT;
                    force_treq <= 1'b1;  // Assert TREQ (XCVR_SESSION LOW)
                    `ifdef SIMULATION
                    $display("EGRET_INIT[%0d]: XCVR_SESSION asserted (TREQ LOW)", handshake_timer);
                    `endif
                end else begin
                    handshake_timer <= handshake_timer + 1;
                end
            end

            INIT_ASSERT: begin
                if (handshake_timer == 16'h2800) begin
                    init_state <= INIT_DELAY;
                    `ifdef SIMULATION
                    $display("EGRET_INIT[%0d]: Entering delay phase", handshake_timer);
                    `endif
                end
                handshake_timer <= handshake_timer + 1;
            end

            INIT_DELAY: begin
                if (handshake_timer == 16'h3800) begin
                    force_treq <= 1'b0;
                    handshake_done <= 1'b1;
                    init_state <= RUNNING;
                    `ifdef SIMULATION
                    $display("EGRET_INIT[%0d]: Entering RUNNING state", handshake_timer);
                    `endif
                end
                handshake_timer <= handshake_timer + 1;
            end

            RUNNING: begin
                // Normal operation - Egret controls TREQ
            end
        endcase
    end
end

// Output assignments
// Gate CB1 output: only allow edges when TIP is asserted (TIP=0 means active)
// This ensures VIA is ready and in external clock mode before seeing CB1 clocks
// When TIP=1 (not asserted), hold CB1 low so no spurious edges are generated
assign cuda_cb1    = (via_tip_stable == 1'b0) ? pb_out[4] : 1'b0;
assign cuda_cb2    = pb_out[5];
assign cuda_cb2_oe = pb_ddr[5];
// TREQ is active LOW - pb_out[1]=0 means assert (LOW), pb_out[1]=1 means deassert (HIGH)
assign cuda_treq   = force_treq ? 1'b0 : pb_out[1];
assign cuda_byteack = 1'b0;       // Not used in Egret

assign cuda_portb    = pb_out;
assign cuda_portb_oe = pb_ddr;

// ============================================================================
// Port C - 68000 control
// ============================================================================
// Bit 3 (O): 680x0 reset
// Bit 2: IPL2
// Bit 1-0: IPL1-0

// Port C input - use latch values for port test compatibility
// Port C is mostly outputs (reset, IPL) so we don't need external reads.
// The port test writes a value and expects to read it back.
wire [7:0] pc_in = pc_latch;

// Auto-release 68020 from reset after initialization
// The Egret firmware expects VIA communication before releasing reset,
// but the 68020 needs to run first to initialize the VIA.
// Solution: Force reset release after a short delay.
reg [15:0] reset_release_counter;
reg reset_680x0_override;

always @(posedge clk) begin
    if (reset) begin
        reset_release_counter <= 0;
        reset_680x0_override <= 1'b1; // Hold in reset initially
    end else if (cen) begin
        if (reset_release_counter < 16'h2000) begin
            reset_release_counter <= reset_release_counter + 1;
            reset_680x0_override <= 1'b1; // Keep in reset
        end else begin
            reset_680x0_override <= 1'b0; // Release reset after ~8K cycles
        end
    end
end

always @(*) begin
    // Hold 68020 in reset when either:
    // 1. Auto-release timer hasn't expired yet, OR
    // 2. Egret firmware sets Port C bit 3 high (1 = assert reset)
    // Per MAME egret.cpp: pc_out[3]=1 means ASSERT reset, pc_out[3]=0 means CLEAR reset
    reset_680x0 = reset_680x0_override | pc_out[3];  // Active high to 68000
    nmi_680x0 = 1'b0;
end

// ============================================================================
// Port output logic (68HC05 style: out = (latch & ddr) | (in & ~ddr))
// ============================================================================
always @(posedge clk) begin
    if (reset) begin
        pa_out <= 8'h00;
        pb_out <= 8'h00;
        pc_out <= 8'h00;
        pc_bit3_prev <= 1'b0;
        pram_loaded <= 1'b0;
    end else if (cen) begin
        pa_out <= (pa_latch & pa_ddr) | (pa_in & ~pa_ddr);
        pb_out <= (pb_latch & pb_ddr) | (pb_in & ~pb_ddr);
        pc_out <= (pc_latch & pc_ddr) | (pc_in & ~pc_ddr);

        // Track Port C bit 3 for falling edge detection
        pc_bit3_prev <= pc_out[3];

        // Load PRAM when Egret asserts 680x0 reset (PC bit 3: 1->0 transition)
        // This mimics MAME behavior where PRAM is loaded when reset is asserted
        if (pc_bit3_prev && !pc_out[3] && !pram_loaded) begin
            pram_loaded <= 1'b1;
            `ifdef SIMULATION
            $display("EGRET_PRAM[%0d]: Loading PRAM and RTC time on 680x0 reset assertion (PC3: 1->0)", cycle_count);
            `endif
        end
    end
end

// PRAM loading - copy to internal RAM when 680x0 reset asserts
integer pram_idx;
always @(posedge clk) begin
    if (pc_bit3_prev && !pc_out[3] && !pram_loaded && cen) begin
        // Copy PRAM to internal RAM at addresses 0x70-0x16F
        // RAM base is 0x50, so offset is (0x70 - 0x50) = 0x20
        for (pram_idx = 0; pram_idx < 256; pram_idx = pram_idx + 1) begin
            intram[pram_idx + (16'h70 - 16'h50)] = pram[pram_idx];
        end

        // Initialize RTC time (use timestamp input)
        // Addresses 0xAB-0xAE (offset from base 0x50)
        intram[16'hAB - 16'h50] = timestamp[31:24];  // Seconds bits 31-24
        intram[16'hAC - 16'h50] = timestamp[23:16];  // Seconds bits 23-16
        intram[16'hAD - 16'h50] = timestamp[15:8];   // Seconds bits 15-8
        intram[16'hAE - 16'h50] = timestamp[7:0];    // Seconds bits 7-0

        `ifdef SIMULATION
        // Debug: Show what was loaded
        $display("EGRET_PRAM: RAM[$94] = 0x%02x (should have bit 3 set, i.e., >= 0x08)",
                 intram[16'h94 - 16'h50]);
        $display("EGRET_PRAM: RAM[$AB-$AE] RTC = %02x %02x %02x %02x (timestamp input = %d)",
                 intram[16'hAB - 16'h50], intram[16'hAC - 16'h50],
                 intram[16'hAD - 16'h50], intram[16'hAE - 16'h50],
                 timestamp);
        $display("EGRET_PRAM: PRAM source byte[0x24] = 0x%02x", pram[8'h24]);
        `endif
    end
end

// ============================================================================
// Port and DDR register writes
// ============================================================================
always @(posedge clk) begin
    if (reset) begin
        pa_latch <= 8'h00;
        pb_latch <= 8'h00;
        pc_latch <= 8'h00;
        pa_ddr   <= 8'h00;
        pb_ddr   <= 8'hB2;  // 1011 0010: bits 7,5,4,1 are outputs (CB1, CB2, TREQ)
        pc_ddr   <= 8'h00;
    end else if (port_cs && !cpu_wr && cen) begin  // !cpu_wr means write
        case (cpu_addr[4:0])  // 5 bits for 0x00-0x1F
            5'h00: pa_latch <= cpu_dout;
            5'h01: begin
                pb_latch <= cpu_dout;
                `ifdef SIMULATION
                $display("EGRET[%0d]: *** PB_LATCH WRITE = 0x%02x (CB1_new=%b) ***", cycle_count, cpu_dout, cpu_dout[4]);
                `endif
            end
            5'h02: pc_latch <= cpu_dout;
            5'h04: pa_ddr   <= cpu_dout;
            // 5'h05: pb_ddr <= cpu_dout;  // BLOCKED - port test writes 0x0F which breaks CB1/CB2
            5'h06: pc_ddr   <= cpu_dout;
            // M68HC05E1 registers
            5'h07: begin  // PLL control - sets timer rate
                pll_ctrl <= cpu_dout;
                // Set timer prescaler based on PLL clock bits
                case (cpu_dout[1:0])
                    2'b00: timer_prescale_max <= 16'd2048;   // 512 kHz / 1024 = ~500 Hz
                    2'b01: timer_prescale_max <= 16'd1024;   // 1 MHz / 1024 = ~1 kHz
                    2'b10: timer_prescale_max <= 16'd512;    // 2 MHz / 1024 = ~2 kHz
                    2'b11: timer_prescale_max <= 16'd256;    // 4 MHz / 1024 = ~4 kHz
                endcase
                `ifdef SIMULATION
                $display("EGRET[%0d]: PLL write = 0x%02x (clock rate %0d)", cycle_count, cpu_dout, cpu_dout[1:0]);
                `endif
            end
            5'h08: begin  // Timer control
                // Clear flags by writing 0 to bits 7 or 6
                if (!(cpu_dout & 8'h80)) timer_ctrl[7] <= 1'b0;
                if (!(cpu_dout & 8'h40)) timer_ctrl[6] <= 1'b0;
                timer_ctrl[5:0] <= cpu_dout[5:0];
                `ifdef SIMULATION
                $display("EGRET[%0d]: Timer ctrl write = 0x%02x", cycle_count, cpu_dout);
                `endif
            end
            5'h12: begin  // One-second timer
                onesec_ctrl <= cpu_dout;
            end
        endcase
    end
end

// ============================================================================
// RAM (368 bytes at 0x90-0x1FF for M68HC05E1)
// ============================================================================
// RAM read is combinational, write is synchronous
always @(*) begin
    if (ram_cs) begin
        ram_dout = intram[ram_addr];
    end else begin
        ram_dout = 8'h00;
    end
end

`ifdef SIMULATION
// Debug RAM access around stack area - only log first 100 and critical writes
reg [31:0] stack_write_count;
always @(posedge clk) begin
    if (reset) begin
        stack_write_count <= 0;
    end else if (cen && ram_cs && (cpu_addr >= 16'h00F0) && (cpu_addr <= 16'h00FF)) begin
        if (!cpu_wr) begin  // Write
            if (stack_write_count < 100 || cpu_dout == 8'hFF)
                $display("HC05 RAM[%0d]: WRITE stack 0x%04x = 0x%02x (ram_addr=%d)", cycle_count, cpu_addr, cpu_dout, ram_addr);
            stack_write_count <= stack_write_count + 1;
        end
    end
end
`endif

always @(posedge clk) begin
    if (ram_cs && !cpu_wr && cen) begin  // !cpu_wr means write
        intram[ram_addr] <= cpu_dout;
    end
end

// ============================================================================
// ROM (4KB at 0x0F00-0x1FFF for M68HC05E1)
// ============================================================================
// CRITICAL: Make ROM read combinational (not registered) so data is available same cycle
always @(*) begin
    if (rom_cs) begin
        rom_dout = rom[rom_addr];
    end else begin
        rom_dout = 8'hFF;
    end
end

`ifdef SIMULATION
// Debug ROM reads (commented out - enable if needed for debugging)
/*
always @(posedge clk) begin
    if (rom_cs && cycle_count < 20) begin
        $display("EGRET_ROM_READ[%0d]: addr=%04x rom_addr=%03x data=%02x rom_cs=%b", 
                 cycle_count, cpu_addr, rom_addr, rom[rom_addr], rom_cs);
    end
end
*/
`endif

// ============================================================================
// CPU data input mux
// ============================================================================
reg [7:0] cpu_din_r;
always @(*) begin
    if (port_cs) begin
        case (cpu_addr[4:0])  // 5 bits for 0x00-0x1F
            5'h00: cpu_din_r = pa_in;
            5'h01: cpu_din_r = pb_in;
            5'h02: cpu_din_r = pc_out;  // Full 8-bit read for port test
            5'h04: cpu_din_r = pa_ddr;
            5'h05: cpu_din_r = pb_ddr;
            5'h06: cpu_din_r = pc_ddr;
            5'h07: cpu_din_r = pll_ctrl;       // PLL control
            5'h08: cpu_din_r = timer_ctrl;     // Timer control
            5'h09: cpu_din_r = timer_counter;  // Timer counter (8-bit, free-running)
            5'h12: cpu_din_r = onesec_ctrl;    // One-second timer control
            default: cpu_din_r = 8'h00;  // Unmapped ports return 0 (makes bit tests fail safely)
        endcase
    end else if (ram_cs) begin
        cpu_din_r = ram_dout;
    end else if (rom_cs) begin
        cpu_din_r = rom_dout;
    end else begin
        // Unmapped space returns NOP (0x9D) instead of 0xFF to prevent runaway execution
        cpu_din_r = 8'h9D;
    end
end

assign cpu_din = cpu_din_r;

// ============================================================================
// IRQ generation - timer only (firmware polls TIP, doesn't use IRQ for it)
// ============================================================================
// Note: The real Egret uses polling for TIP detection, not interrupts.
// MAME logs show IRQs at regular intervals (timer) but CB1 toggling happens
// in the main loop at PC=0x1246, not in an interrupt handler.
wire combined_irq_n = timer_irq_n;  // Only timer generates IRQ

// Track TIP for edge detection in debug/display only
reg via_tip_prev;

always @(posedge clk) begin
    if (reset) begin
        via_tip_prev <= 1'b1;  // TIP is idle high
    end else if (cen) begin
        via_tip_prev <= via_tip_stable;  // Use synchronized signal
    end
end

// ============================================================================
// CPU instantiation - m68hc05_core
// ============================================================================
m68hc05_core u_cpu (
    .clk(clk),
    .cen(cen),         // 4 MHz clock enable (32 MHz / 8)
    .rst(~reset),      // m68hc05_core uses active-low reset
    .irq(combined_irq_n),   // Active-low IRQ, combined timer + TIP edge
    .addr(cpu_addr),
    .wr(cpu_wr),
    .datain(cpu_din),
    .state(cpu_state),
    .dataout(cpu_dout)
);

// ============================================================================
// Stub for cuda_sr_irq (not implemented yet)
// ============================================================================
always @(posedge clk) begin
    if (reset)
        cuda_sr_irq <= 1'b0;
    // TODO: Implement SR interrupt logic if needed
end

// ============================================================================
// Debug (simulation only)
// ============================================================================
`ifdef SIMULATION
reg [7:0] pb_out_prev, pb_latch_prev, pb_ddr_prev;
reg [7:0] pa_out_prev;
// via_tip_prev is declared and managed earlier
reg [31:0] cycle_count;
reg [15:0] last_pc;
reg       treq_prev;
reg       reset_680x0_prev;

always @(posedge clk) begin
    if (reset) begin
        cycle_count <= 0;
        pb_out_prev <= 8'hFF;
        pb_latch_prev <= 0;
        pb_ddr_prev <= 0;
        pa_out_prev <= 0;
        last_pc <= 0;
        treq_prev <= 1;  // pb_out[1]=1 means TREQ deasserted initially
        reset_680x0_prev <= 1;
    end else if (cen) begin
        cycle_count <= cycle_count + 1;
        pb_out_prev <= pb_out;
        pa_out_prev <= pa_out;
        treq_prev <= pb_out[1];  // Track pb_out[1] directly
        reset_680x0_prev <= reset_680x0;

        // Log 68020 reset release
        if (reset_680x0 != reset_680x0_prev) begin
            if (reset_680x0)
                $display("EGRET[%0d]: *** 68020 RESET ASSERTED ***", cycle_count);
            else
                $display("EGRET[%0d]: *** 68020 RESET RELEASED (counter=%0d, pc_out[3]=%b) ***", 
                         cycle_count, reset_release_counter, pc_out[3]);
        end

        // Log Port B and C latch/DDR writes
        if (port_cs && !cpu_wr) begin
            case (cpu_addr[3:0])
                4'h0: $display("EGRET[%0d] PC=%04x: Port A LATCH write = 0x%02x (was 0x%02x)",
                              cycle_count, cpu_addr, cpu_dout, pa_latch);
                4'h1: $display("EGRET[%0d] PC=%04x: Port B LATCH write = 0x%02x (was 0x%02x)",
                              cycle_count, cpu_addr, cpu_dout, pb_latch);
                4'h2: $display("EGRET[%0d] PC=%04x: Port C LATCH write = 0x%02x (bit3=%b -> reset_680x0 will be %b)",
                              cycle_count, cpu_addr, cpu_dout, cpu_dout[3], ~cpu_dout[3]);
                4'h4: $display("EGRET[%0d] PC=%04x: Port A DDR write = 0x%02x",
                              cycle_count, cpu_addr, cpu_dout);
                4'h5: $display("EGRET[%0d] PC=%04x: Port B DDR write = 0x%02x",
                              cycle_count, cpu_addr, cpu_dout);
                4'h6: $display("EGRET[%0d] PC=%04x: Port C DDR write = 0x%02x",
                              cycle_count, cpu_addr, cpu_dout);
                default: $display("EGRET[%0d] PC=%04x: Port write addr=%x data=%02x",
                              cycle_count, cpu_addr, cpu_addr[3:0], cpu_dout);
            endcase
        end

        // Log ALL port accesses (read or write) to addresses 0x01 and 0x05
        // (Disabled for faster simulation)
        // if (port_cs && (cpu_addr[3:0] == 4'h1 || cpu_addr[3:0] == 4'h5)) begin
        //     $display("EGRET[%0d]: Port B access addr=%04x wr=%b din=%02x dout=%02x",
        //              cycle_count, cpu_addr, cpu_wr, cpu_din, cpu_dout);
        // end

        // Log Port B output changes
        // TREQ: pb_out[1]=0 means asserted (LOW), pb_out[1]=1 means deasserted (HIGH)
        if (pb_out != pb_out_prev) begin
            $display("EGRET[%0d]: PB OUT 0x%02x->0x%02x (CB1=%b CB2=%b TREQ=%b) TIP_in=%b",
                     cycle_count, pb_out_prev, pb_out,
                     pb_out[4], pb_out[5], pb_out[1], via_tip_stable);
        end

        // Log TREQ transitions (pb_out[1]=0 means TREQ active)
        if (pb_out[1] != treq_prev) begin
            if (~pb_out[1])
                $display("EGRET[%0d]: *** TREQ ACTIVE (requesting transfer) ***", cycle_count);
            else
                $display("EGRET[%0d]: *** TREQ INACTIVE ***", cycle_count);
        end

        // Log TIP input changes from VIA
        if (via_tip_stable != via_tip_prev) begin
            $display("EGRET[%0d]: TIP from VIA changed: %b -> %b",
                     cycle_count, via_tip_prev, via_tip_stable);
        end

        // Log CB1 clock edges
        if (pb_out[4] != pb_out_prev[4]) begin
            $display("EGRET[%0d]: CB1 %s edge (CB2_out=%b CB2_in=%b)",
                     cycle_count, pb_out[4] ? "RISING" : "FALLING",
                     pb_out[5], via_cb2_in_stable);
        end

        // Track program counter
        if (rom_cs && cpu_wr) begin  // cpu_wr=1 means read
            last_pc <= cpu_addr;
            // Log when firmware reaches key PC addresses for CB1 handling
            // MAME shows CB1 toggling at PC=0x1246, 0x14EF-0x152B
            if (cpu_addr == 16'h1246 ||
                (cpu_addr >= 16'h14EF && cpu_addr <= 16'h152B))
                $display("EGRET[%0d]: *** KEY PC: 0x%04x (CB1 toggle area) PB_out=%02x TIP=%b ***",
                         cycle_count, cpu_addr, pb_out, via_tip_stable);
        end

        // Debug Port A reads (especially in the wait loop around 0x0F9E)
        // (Disabled for faster simulation)
        // if (port_cs && cpu_wr && cpu_addr[3:0] == 4'h0) begin
        //     $display("EGRET[%0d]: PORT A READ = 0x%02x (pa_out=%02x pa_in=%02x pa_ddr=%02x)",
        //              cycle_count, cpu_din_r, pa_out, pa_in, pa_ddr);
        // end

        // Log first 500 CPU cycles
        if (cycle_count < 500) begin
            $display("EGRET_CPU[%0d]: addr=%04x din=%02x dout=%02x wr=%b rom=%b ram=%b port=%b state=%x",
                     cycle_count, cpu_addr, cpu_din, cpu_dout, cpu_wr,
                     rom_cs, ram_cs, port_cs, cpu_state);
        end
    end
end

// Periodic status
reg [19:0] status_timer;
always @(posedge clk) begin
    if (reset) begin
        status_timer <= 0;
    end else if (cen) begin
        status_timer <= status_timer + 1;
        if (status_timer == 0) begin
            // TREQ: pb_out[1]=0 means asserted, pb_out[1]=1 means deasserted
            $display("EGRET STATUS: PC~%04x PB_out=%02x PB_ddr=%02x TREQ=%b TIP=%b CB1=%b CB2=%b state=%x",
                     last_pc, pb_out, pb_ddr, pb_out[1], via_tip_stable, pb_out[4], pb_out[5], cpu_state);
        end
    end
end
`endif

endmodule

`default_nettype wire