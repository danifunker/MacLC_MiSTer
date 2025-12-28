// Egret microcontroller for Mac LC
// Uses jt6805 CPU core with real Egret ROM (341S0850)
//
// Based on MAME's egret.cpp by R. Belmont
// jt6805 core by Jose Tejada (@topapate)
//
// This module has the same interface as cuda_maclc.sv for easy switching

`default_nettype none

module egret (
    input         clk,
    input         clk8_en,
    input         reset,

    // RTC timestamp initialization (Unix time)
    input  [32:0] timestamp,

    // Direct VIA Port B connections
    input         via_tip,          // VIA Port B bit 5 - Transaction In Progress (directly directly active low)
    input         via_byteack_in,   // VIA Port B bit 4 - from VIA
    output        cuda_treq,        // Port B bit 3 - Transfer Request (active LOW)
    output        cuda_byteack,     // Port B bit 4 - Byte Acknowledge

    // VIA Shift Register interface (CB1/CB2)
    output        cuda_cb1,         // CB1 - Shift clock (Egret drives in external mode)
    input         via_cb2_in,       // CB2 - Data from VIA (when VIA sending)
    output        cuda_cb2,         // CB2 - Data to VIA (when Egret sending)
    output        cuda_cb2_oe,      // CB2 output enable

    // VIA SR control signals
    input         via_sr_read,      // VIA is reading SR (shift in mode)
    input         via_sr_write,     // VIA has written SR (shift out mode)
    input         via_sr_ext_clk,   // VIA is in external clock mode
    input         via_sr_dir,       // VIA shift direction: 0=in, 1=out
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

// ============================================================================
// Clock generation for 68HC05
// Egret runs at 32.768kHz * 128 = 4.194 MHz
// We use clk8_en as our clock enable (8MHz), divide by 2 for ~4MHz
// ============================================================================
reg cen_div;
wire cen = clk8_en & cen_div;

always @(posedge clk) begin
    if (reset)
        cen_div <= 1'b0;
    else if (clk8_en)
        cen_div <= ~cen_div;
end

// ============================================================================
// Memory map for Egret (68HC05 with 8KB address space)
// ============================================================================
// 0x0000-0x000F: I/O registers (Ports A, B, C, DDR, Timer)
// 0x0010-0x007F: Internal RAM (112 bytes)
// 0x0080-0x00FF: Extended RAM (128 bytes, for PRAM at 0x70-0x16F)
// 0x0100-0x010F: More RAM
// 0x0F00-0x1FFF: ROM (4KB, Egret firmware)

localparam ROM_SIZE = 4352;  // 0x1100 bytes

// CPU signals
wire        cpu_wr;
wire [12:0] cpu_addr;
wire [ 7:0] cpu_dout;
reg  [ 7:0] cpu_din;
wire        cpu_tstop;
wire        tirq;
reg         ext_irq;

// Port registers (directly directly directly directly 68HC05 style)
reg  [7:0] pa_ddr, pb_ddr;
reg  [7:0] pa_latch, pb_latch;
reg  [3:0] pc_ddr, pc_latch;

// Port I/O
reg  [7:0] pa_out, pb_out;
reg  [3:0] pc_out;

// Timer registers
reg  [7:0] tdr, tcr;
reg  [6:0] pres;
reg  [1:0] cendiv_timer;
reg        fpin_l, prmx_l;

localparam TIR = 7, TIM = 6;

// Memory
reg  [7:0] intram[0:255];
reg  [7:0] ram_dout;

// ROM
reg  [7:0] rom[0:ROM_SIZE-1];
reg  [7:0] rom_dout;

// Initialize ROM from hex file
initial begin
`ifdef SIMULATION
    $readmemh("../rtl/egret_rom.hex", rom);
`else
    $readmemh("rtl/egret_rom.hex", rom);
`endif
end

// Address decoding
wire port_cs = (cpu_addr < 13'h0010);
wire ram_cs  = (cpu_addr >= 13'h0010) && (cpu_addr < 13'h0110);
wire rom_cs  = (cpu_addr >= 13'h0F00);
wire [12:0] rom_offset = cpu_addr - 13'h0F00;

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
    pa_out[3],        // Bit 3: reset readback
    1'b1,             // Bit 2: keyboard power (not pressed)
    1'b1,             // Bit 1: PSU
    1'b1              // Bit 0: control panel
};

always @(*) begin
    adb_data_out = pa_out[7];
end

// ============================================================================
// Port B - VIA interface (directly directly directly directly directly directly directly directly this is the key interface)
// ============================================================================
// Bit 7 (O): DFAC clock (I2C SCL)
// Bit 6 (I/O): DFAC data (I2C SDA)
// Bit 5 (I/O): VIA shift register data = CB2
// Bit 4 (O): VIA clock = CB1
// Bit 3 (I): VIA SYS_SESSION = TIP from VIA
// Bit 2 (I): VIA_FULL (directly directly directly directly directly tied high for now)
// Bit 1 (O): VIA XCEIVER SESSION = TREQ to VIA
// Bit 0 (I): +5V sense

wire [7:0] pb_in = {
    pb_out[7],        // Bit 7: DFAC clock readback
    1'b1,             // Bit 6: DFAC data (not connected)
    via_cb2_in,       // Bit 5: CB2 from VIA
    pb_out[4],        // Bit 4: CB1 readback
    via_tip,          // Bit 3: TIP from VIA (directly directly directly directly directly directly directly directly directly 0 = asserted)
    1'b1,             // Bit 2: VIA_FULL (directly directly directly directly directly directly tied high)
    pb_out[1],        // Bit 1: TREQ readback
    1'b1              // Bit 0: +5V sense
};

// Output assignments to match cuda_maclc interface
assign cuda_cb1    = pb_out[4];
assign cuda_cb2    = pb_out[5];
assign cuda_cb2_oe = pb_ddr[5];
assign cuda_treq   = ~pb_out[1];  // Directly directly directly active low (invert)
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
    reset_680x0 = ~pc_out[3];  // Directly directly directly active high to 68000
    nmi_680x0 = 1'b0;
end

// ============================================================================
// Port output logic (directly directly directly directly directly directly 68HC05 style: out = (latch & ddr) | (in & ~ddr))
// ============================================================================
always @(posedge clk) begin
    pa_out <= (pa_latch & pa_ddr) | (pa_in & ~pa_ddr);
    pb_out <= (pb_latch & pb_ddr) | (pb_in & ~pb_ddr);
    pc_out <= (pc_latch & pc_ddr) | (pc_in & ~pc_ddr);
end

// ============================================================================
// Timer
// ============================================================================
wire fpin = cendiv_timer[1];
wire [7:0] prfull = {pres, fpin};
wire prmx = prfull[tcr[2:0]];
wire [7:0] nx_tdr = tdr - 8'd1;

assign tirq = tcr[TIR] & ~tcr[TIM];

always @(posedge clk or posedge reset) begin
    if (reset) begin
        pa_latch <= 8'h00;
        pa_ddr   <= 8'h00;
        pb_latch <= 8'h00;
        pb_ddr   <= 8'h00;
        pc_latch <= 4'h0;
        pc_ddr   <= 4'h0;
        tdr      <= 8'hFF;
        tcr      <= 8'h40;
        pres     <= 7'h7F;
        cendiv_timer <= 2'b00;
        fpin_l   <= 1'b0;
        prmx_l   <= 1'b0;
        ext_irq  <= 1'b0;
        cuda_sr_irq <= 1'b0;
    end else begin
        // Timer
        if (cen && !cpu_tstop) begin
            cendiv_timer <= cendiv_timer + 2'd1;
        end

        fpin_l <= fpin;
        prmx_l <= prmx;

        if (fpin && !fpin_l) begin
            pres <= pres + 7'd1;
        end

        if (prmx && !prmx_l) begin
            tdr <= nx_tdr;
            if (nx_tdr == 8'd0) begin
                tcr[TIR] <= 1'b1;
            end
        end

        // Port writes
        if (port_cs && cpu_wr && cen) begin
            case (cpu_addr[3:0])
                4'h0: pa_latch <= cpu_dout;
                4'h1: pb_latch <= cpu_dout;
                4'h2: pc_latch <= cpu_dout[3:0];
                4'h4: pa_ddr   <= cpu_dout;
                4'h5: pb_ddr   <= cpu_dout;
                4'h6: pc_ddr   <= cpu_dout[3:0];
                4'h8: tdr      <= cpu_dout;
                4'h9: begin
                    tcr <= cpu_dout;
                    if (cpu_dout[3]) pres <= 7'h7F;
                end
            endcase
        end
    end
end

// ============================================================================
// RAM
// ============================================================================
always @(posedge clk) begin
    if (ram_cs) begin
        ram_dout <= intram[cpu_addr[7:0]];
        if (cpu_wr && cen) begin
            intram[cpu_addr[7:0]] <= cpu_dout;
        end
    end
end

// ============================================================================
// ROM
// ============================================================================
always @(posedge clk) begin
    if (rom_cs && rom_offset < ROM_SIZE) begin
        rom_dout <= rom[rom_offset[11:0]];
    end else begin
        rom_dout <= 8'hFF;
    end
end

// ============================================================================
// Data input mux
// ============================================================================
always @(*) begin
    if (port_cs) begin
        case (cpu_addr[3:0])
            4'h0: cpu_din = pa_out;
            4'h1: cpu_din = pb_out;
            4'h2: cpu_din = {4'hF, pc_out};
            4'h8: cpu_din = tdr;
            4'h9: cpu_din = tcr;
            default: cpu_din = 8'hFF;
        endcase
    end else if (ram_cs) begin
        cpu_din = ram_dout;
    end else if (rom_cs) begin
        cpu_din = rom_dout;
    end else begin
        cpu_din = 8'hFF;
    end
end

// ============================================================================
// CPU instantiation
// ============================================================================
jt6805 u_cpu (
    .rst   (reset),
    .clk   (clk),
    .cen   (cen),
    .irq   (ext_irq),
    .tirq  (tirq),
    .wr    (cpu_wr),
    .tstop (cpu_tstop),
    .addr  (cpu_addr),
    .din   (cpu_din),
    .dout  (cpu_dout)
);

// ============================================================================
// Debug
// ============================================================================
`ifdef SIMULATION
reg [7:0] pb_out_prev;
always @(posedge clk) begin
    if (cen && !reset) begin
        pb_out_prev <= pb_out;
        // Log Port B changes (VIA interface)
        if (pb_out != pb_out_prev) begin
            $display("EGRET: Port B = 0x%02x (CB1=%b CB2=%b TREQ=%b) TIP=%b",
                     pb_out, pb_out[4], pb_out[5], ~pb_out[1], via_tip);
        end
        // Log CPU address for debugging
        if (cpu_addr >= 13'h0F00 && cpu_addr < 13'h0F10) begin
            $display("EGRET: CPU addr=0x%04x din=0x%02x dout=0x%02x wr=%b",
                     cpu_addr, cpu_din, cpu_dout, cpu_wr);
        end
    end
end
`endif

endmodule

`default_nettype wire
