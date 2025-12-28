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
// TEMPORARY FOR SIMULATION: Force cen=1 because m68hc05_core has no clock enable
// The CPU runs every cycle, so peripherals must too
// ============================================================================
wire cen = 1'b1;  // TEMPORARY: Always enabled for simulation testing

// Production version (uncomment when using dedicated PLL):
// wire cen = clk8_en;  // Direct passthrough when using dedicated PLL clock

// Uncomment this if NOT using dedicated PLL (fallback to divide-by-2 from 8 MHz):
/*
reg cen_div;
wire cen = clk8_en & cen_div;

always @(posedge clk) begin
    if (reset)
        cen_div <= 1'b0;
    else if (clk8_en)
        cen_div <= ~cen_div;
end
*/

// ============================================================================
// Memory map for Egret (68HC05 with 64KB address space from CPU core)
// ============================================================================
// 0x0000-0x000F: I/O registers (Ports A, B, C, DDR, etc.)
// 0x0010-0x004F: Unmapped (reads as ROM due to mirroring)
// 0x0050-0x01FF: Internal RAM (448 bytes for PRAM, RTC, variables)
// 0x0200-0xFFFF: ROM (4KB, repeats every 4KB due to [11:0] addressing)
//
// The 4KB ROM repeats throughout the address space, so:
// - 0x0F0F (where reset vector points) → ROM offset 0xF0F
// - 0xFFFE/FFFF (reset vectors) → ROM offset 0xFFE/FFF

localparam ROM_SIZE = 4096;  // 4KB

// CPU signals (from m68hc05_core)
wire [15:0] cpu_addr;
wire        cpu_wr;
wire [7:0]  cpu_din;
wire [7:0]  cpu_dout;
wire [3:0]  cpu_state;

// Port registers (68HC05 style)
reg  [7:0] pa_ddr, pb_ddr;
reg  [7:0] pa_latch, pb_latch;
reg  [3:0] pc_ddr, pc_latch;

// Port I/O
reg  [7:0] pa_out, pb_out;
reg  [3:0] pc_out;

// Memory
reg  [7:0] intram[0:447];    // Internal RAM (0x50-0x1FF)
reg  [7:0] ram_dout;

// ROM
reg  [7:0] rom[0:ROM_SIZE-1];
reg  [7:0] rom_dout;

// Initialize ROM from hex file
initial begin
`ifdef SIMULATION
    $readmemh("../rtl/egret/egret_rom.hex", rom);
    $display("EGRET ROM: Loaded %0d bytes from ../rtl/egret/egret_rom.hex", ROM_SIZE);
`else
    $readmemh("rtl/egret/egret_rom.hex", rom);
`endif
end

// Address decoding
// ROM needs to be accessible where the reset vector points (0x0F0F suggests ROM at low addresses)
// Map ROM to cover the address space the firmware expects
wire port_cs = (cpu_addr < 16'h0010);  // I/O ports at 0x00-0x0F
wire ram_cs  = (cpu_addr >= 16'h0050) && (cpu_addr < 16'h0200);  // RAM at 0x50-0x1FF
// ROM everywhere else - covers reset vectors and main code
// Exclude I/O and RAM regions
wire rom_cs  = !port_cs && !ram_cs;
wire [11:0] rom_addr = cpu_addr[11:0];  // 4KB ROM wraps every 4KB
wire [8:0]  ram_addr = cpu_addr[8:0] - 9'h50;

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

wire [7:0] pa_in = {
    pa_out[7],        // Bit 7: readback
    adb_data_in,      // Bit 6: ADB data in
    1'b1,             // Bit 5: system type = Egret controls power
    pa_out[4],        // Bit 4: DFAC latch readback
    1'b0,              // Bit 3: reset readback
    1'b1,             // Bit 2: keyboard power (not pressed)
    1'b1,             // Bit 1: PSU
    1'b1              // Bit 0: control panel
};

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

wire [7:0] pb_in = {
    pb_out[7],        // Bit 7: DFAC clock readback
    1'b1,             // Bit 6: DFAC data (not connected)
    via_cb2_in,       // Bit 5: CB2 from VIA
    pb_out[4],        // Bit 4: CB1 readback
    via_tip,          // Bit 3: TIP from VIA (0 = asserted)
    1'b1,             // Bit 2: VIA_FULL (tied high)
    pb_out[1],        // Bit 1: TREQ readback
    1'b1              // Bit 0: +5V sense
};

// Output assignments
assign cuda_cb1    = pb_out[4];
assign cuda_cb2    = pb_out[5];
assign cuda_cb2_oe = pb_ddr[5];
assign cuda_treq   = ~pb_out[1];  // Active low (invert)
assign cuda_byteack = 1'b0;       // Not used in Egret

assign cuda_portb    = pb_out;
assign cuda_portb_oe = pb_ddr;

// ============================================================================
// Port C - 68000 control
// ============================================================================
// Bit 3 (O): 680x0 reset
// Bit 2: IPL2
// Bit 1-0: IPL1-0

wire [3:0] pc_in = {
    pc_out[3],        // Bit 3: reset readback
    1'b1,             // Bit 2: IPL2
    1'b1,             // Bit 1: IPL1
    1'b1              // Bit 0: IPL0
};

always @(*) begin
    reset_680x0 = ~pc_out[3];  // Active high to 68000
    nmi_680x0 = 1'b0;
end

// ============================================================================
// Port output logic (68HC05 style: out = (latch & ddr) | (in & ~ddr))
// ============================================================================
always @(posedge clk) begin
    if (reset) begin
        pa_out <= 8'h00;
        pb_out <= 8'h00;
        pc_out <= 4'h0;
    end else if (cen) begin
        pa_out <= (pa_latch & pa_ddr) | (pa_in & ~pa_ddr);
        pb_out <= (pb_latch & pb_ddr) | (pb_in & ~pb_ddr);
        pc_out <= (pc_latch & pc_ddr) | (pc_in & ~pc_ddr);
    end
end

// ============================================================================
// Port and DDR register writes
// ============================================================================
always @(posedge clk) begin
    if (reset) begin
        pa_latch <= 8'h00;
        pb_latch <= 8'h00;
        pc_latch <= 4'h0;
        pa_ddr   <= 8'h00;
        pb_ddr   <= 8'h00;
        pc_ddr   <= 4'h0;
    end else if (port_cs && !cpu_wr && cen) begin  // !cpu_wr means write
        case (cpu_addr[3:0])
            4'h0: pa_latch <= cpu_dout;
            4'h1: pb_latch <= cpu_dout;
            4'h2: pc_latch <= cpu_dout[3:0];
            4'h4: pa_ddr   <= cpu_dout;
            4'h5: pb_ddr   <= cpu_dout;
            4'h6: pc_ddr   <= cpu_dout[3:0];
        endcase
    end
end

// ============================================================================
// RAM (448 bytes at 0x50-0x1FF)
// ============================================================================
// RAM read is combinational, write is synchronous
always @(*) begin
    if (ram_cs) begin
        ram_dout = intram[ram_addr];
    end else begin
        ram_dout = 8'h00;
    end
end

always @(posedge clk) begin
    if (ram_cs && !cpu_wr && cen) begin  // !cpu_wr means write
        intram[ram_addr] <= cpu_dout;
    end
end

// ============================================================================
// ROM (4KB at 0x1000-0x1FFF)
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
        case (cpu_addr[3:0])
            4'h0: cpu_din_r = pa_out;
            4'h1: cpu_din_r = pb_out;
            4'h2: cpu_din_r = {4'hF, pc_out};
            default: cpu_din_r = 8'hFF;
        endcase
    end else if (ram_cs) begin
        cpu_din_r = ram_dout;
    end else if (rom_cs) begin
        cpu_din_r = rom_dout;
    end else begin
        cpu_din_r = 8'hFF;
    end
end

assign cpu_din = cpu_din_r;

// ============================================================================
// CPU instantiation - m68hc05_core
// ============================================================================
m68hc05_core u_cpu (
    .clk(clk),
    .rst(~reset),      // m68hc05_core uses active-low reset
    .irq(1'b1),        // No external IRQ for now
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
reg       via_tip_prev;
reg [31:0] cycle_count;
reg [15:0] last_pc;
reg       treq_prev;

always @(posedge clk) begin
    if (reset) begin
        cycle_count <= 0;
        pb_out_prev <= 8'hFF;
        pb_latch_prev <= 0;
        pb_ddr_prev <= 0;
        pa_out_prev <= 0;
        via_tip_prev <= 1;
        last_pc <= 0;
        treq_prev <= 1;
    end else if (cen) begin
        cycle_count <= cycle_count + 1;
        pb_out_prev <= pb_out;
        pa_out_prev <= pa_out;
        via_tip_prev <= via_tip;
        treq_prev <= ~pb_out[1];

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
            endcase
        end

        // Log Port B output changes
        if (pb_out != pb_out_prev) begin
            $display("EGRET[%0d]: PB OUT 0x%02x->0x%02x (CB1=%b CB2=%b TREQ=%b) TIP_in=%b",
                     cycle_count, pb_out_prev, pb_out,
                     pb_out[4], pb_out[5], ~pb_out[1], via_tip);
        end

        // Log TREQ transitions
        if ((~pb_out[1]) != treq_prev) begin
            if (~pb_out[1])
                $display("EGRET[%0d]: *** TREQ ACTIVE (requesting transfer) ***", cycle_count);
            else
                $display("EGRET[%0d]: *** TREQ INACTIVE ***", cycle_count);
        end

        // Log TIP input changes from VIA
        if (via_tip != via_tip_prev) begin
            $display("EGRET[%0d]: TIP from VIA changed: %b -> %b",
                     cycle_count, via_tip_prev, via_tip);
        end

        // Log CB1 clock edges
        if (pb_out[4] != pb_out_prev[4]) begin
            $display("EGRET[%0d]: CB1 %s edge (CB2_out=%b CB2_in=%b)",
                     cycle_count, pb_out[4] ? "RISING" : "FALLING",
                     pb_out[5], via_cb2_in);
        end

        // Track program counter
        if (rom_cs && cpu_wr) begin  // cpu_wr=1 means read
            last_pc <= cpu_addr;
        end

        // Debug Port A reads (especially in the wait loop around 0x0F9E)
        if (port_cs && cpu_wr && cpu_addr[3:0] == 4'h0) begin
            $display("EGRET[%0d]: PORT A READ = 0x%02x (pa_out=%02x pa_in=%02x pa_ddr=%02x)",
                     cycle_count, cpu_din_r, pa_out, pa_in, pa_ddr);
        end

        // Log first 50 CPU cycles
        if (cycle_count < 50) begin
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
            $display("EGRET STATUS: PC~%04x PB_out=%02x PB_ddr=%02x TREQ=%b TIP=%b CB1=%b CB2=%b state=%x",
                     last_pc, pb_out, pb_ddr, ~pb_out[1], via_tip, pb_out[4], pb_out[5], cpu_state);
        end
    end
end
`endif

endmodule

`default_nettype wire