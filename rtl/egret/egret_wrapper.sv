// egret_wrapper.sv - Egret microcontroller wrapper
// Integrates 68HC05 CPU core with ROM, RAM, and GPIO for Mac LC
//
// This module wraps the 68HC05 CPU and provides:
// - 4KB ROM (Egret firmware)
// - 448 bytes internal RAM (for PRAM, RTC, variables)
// - GPIO port mapping to VIA interface
// - ADB line control
// - Reset control for 68020

module egret_wrapper (
    input  logic        clk,           // 4.194304 MHz CPU clock
    input  logic        rst_n,         // Active low reset
    input  logic        irq_n,         // Active low interrupt (not used currently)
    
    // VIA interface (matches your existing egret.sv)
    input  logic        via_phi2,
    input  logic        via_cs1,
    input  logic        via_cs2,
    input  logic        via_rnw,
    input  logic [7:0]  via_data_in,
    output logic [7:0]  via_data_out,
    input  logic [3:0]  via_addr,
    
    // ADB interface
    output logic        adb_out,       // ADB data line (to device)
    input  logic        adb_in,        // ADB data line (from device)
    
    // System control
    output logic        reset_out,     // Reset to 68020
    
    // DFAC (audio chip) control
    output logic        dfac_scl,      // I2C clock
    output logic        dfac_sda,      // I2C data
    output logic        dfac_latch,    // DFAC latch signal
    
    // PRAM interface (for future save/load)
    output logic [7:0]  pram_addr,
    output logic [7:0]  pram_data_out,
    input  logic [7:0]  pram_data_in,
    output logic        pram_we
);

    // CPU signals
    logic [15:0] cpu_addr;
    logic        cpu_wr;
    logic [7:0]  cpu_datain;
    logic [7:0]  cpu_dataout;
    logic [3:0]  cpu_state;
    
    // ROM signals
    logic [7:0]  rom_data;
    logic        rom_cs;
    
    // RAM signals  
    logic [7:0]  ram_data;
    logic [8:0]  ram_addr;  // 512 bytes (but only 448 used: 0x50-0x1FF)
    logic        ram_cs;
    logic        ram_we;
    
    // GPIO ports (following MAME's egret.cpp port definitions)
    logic [7:0] porta_in, porta_out, porta_ddr;
    logic [7:0] portb_in, portb_out, portb_ddr;
    logic [3:0] portc_in, portc_out, portc_ddr;
    
    // VIA communication signals
    logic via_data_bit;      // VIA shift register data (Port B bit 5)
    logic via_clock_bit;     // VIA clock (Port B bit 4)
    logic xcvr_session;      // VIA transceiver session (Port B bit 1)
    logic sys_session;       // VIA system session input (Port B bit 3)
    logic via_full;          // VIA full flag input (Port B bit 2)
    
    // Internal registers for VIA communication
    logic [7:0] via_shift_reg;
    logic [2:0] via_bit_count;
    
    //==========================================================================
    // 68HC05 CPU Core Instantiation
    //==========================================================================
    m68hc05_core cpu (
        .clk(clk),
        .rst(rst_n),
        .irq(~irq_n),
        .addr(cpu_addr),
        .wr(cpu_wr),
        .datain(cpu_datain),
        .state(cpu_state),
        .dataout(cpu_dataout)
    );
    
    //==========================================================================
    // Memory Map Decoding
    // Based on 68HC05EG memory map:
    // 0x0000-0x003F: I/O and control registers
    // 0x0050-0x01FF: Internal RAM (448 bytes) - used for PRAM, RTC, variables
    // 0x0F00-0x1FFF: ROM (4KB + 256 byte header = 0x1100 bytes in .bin file)
    //                We use 0x1000-0x1FFF (4KB) for the actual ROM
    //==========================================================================
    
    assign rom_cs = (cpu_addr >= 16'h1000) && (cpu_addr <= 16'hFFFF);  // ROM at top 4KB
    assign ram_cs = (cpu_addr >= 16'h0050) && (cpu_addr <= 16'h01FF);  // Internal RAM
    
    // RAM address calculation (0x50-0x1FF maps to 0x000-0x1AF)
    assign ram_addr = cpu_addr[8:0] - 9'h50;
    assign ram_we = ram_cs && !cpu_wr;
    
    // CPU data input mux
    always_comb begin
        if (rom_cs)
            cpu_datain = rom_data;
        else if (ram_cs)
            cpu_datain = ram_data;
        else if (cpu_addr[15:8] == 8'h00)  // I/O ports
            case (cpu_addr[7:0])
                8'h00: cpu_datain = porta_in;   // Port A data
                8'h01: cpu_datain = portb_in;   // Port B data
                8'h02: cpu_datain = {4'h0, portc_in};  // Port C data (4-bit)
                8'h04: cpu_datain = porta_ddr;  // Port A DDR
                8'h05: cpu_datain = portb_ddr;  // Port B DDR
                8'h06: cpu_datain = {4'h0, portc_ddr};  // Port C DDR
                default: cpu_datain = 8'h00;
            endcase
        else
            cpu_datain = 8'h00;
    end
    
    //==========================================================================
    // ROM: Egret Firmware (4KB)
    // This will be initialized with 341S0851.bin (or .hex)
    //==========================================================================
    logic [7:0] rom [0:4095];  // 4KB ROM
    
    initial begin
        // Load firmware from hex file
        $readmemh("rtl/egret/egret_rom.hex", rom);
    end
    
    // ROM address is cpu_addr - 0x1000 (maps 0x1000-0x1FFF to 0x000-0xFFF)
    assign rom_data = rom[cpu_addr[11:0]];
    
    //==========================================================================
    // Internal RAM: 448 bytes (0x50-0x1FF in CPU address space)
    // Used for PRAM (0x70-0x16F = 256 bytes), RTC, and variables
    //==========================================================================
    logic [7:0] ram [0:447];  // 448 bytes
    
    always_ff @(posedge clk) begin
        if (ram_we) begin
            ram[ram_addr[8:0]] <= cpu_dataout;
        end
    end
    
    assign ram_data = ram[ram_addr[8:0]];
    
    // PRAM interface (0x70-0x16F in CPU space = 0x20-0x11F in RAM)
    // For future save/load functionality
    assign pram_addr = ram_addr[7:0] - 8'h20;  // Offset to PRAM region
    assign pram_data_out = (ram_addr >= 9'h020 && ram_addr <= 9'h11F) ? ram[ram_addr] : 8'h00;
    assign pram_we = 1'b0;  // Not implemented yet
    
    //==========================================================================
    // GPIO Port Registers
    // Implemented as memory-mapped I/O at 0x00-0x06
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            porta_out <= 8'h00;
            portb_out <= 8'h00;
            portc_out <= 4'h0;
            porta_ddr <= 8'h00;
            portb_ddr <= 8'h00;
            portc_ddr <= 4'h0;
        end else if (!cpu_wr && (cpu_addr[15:8] == 8'h00)) begin
            case (cpu_addr[7:0])
                8'h00: porta_out <= cpu_dataout;
                8'h01: portb_out <= cpu_dataout;
                8'h02: portc_out <= cpu_dataout[3:0];
                8'h04: porta_ddr <= cpu_dataout;
                8'h05: portb_ddr <= cpu_dataout;
                8'h06: portc_ddr <= cpu_dataout[3:0];
            endcase
        end
    end
    
    //==========================================================================
    // GPIO Port Input Logic
    // Maps physical signals to CPU port inputs based on DDR
    //==========================================================================
    
    // Port A bit definitions (from MAME egret.cpp):
    // Bit 7: O - ADB data line out
    // Bit 6: I - ADB data line in
    // Bit 5: I - System type (0=hardware power switch, 1=Egret controls power)
    // Bit 4: O - DFAC latch
    // Bit 3: O - ? (asserted briefly when resetting 680x0)
    // Bit 2: I - Keyboard power switch
    // Bit 1: ? - PSU enable OUT (type 0) or chassis power switch IN (type 1)
    // Bit 0: ? - Control panel enable IN (LC) or PSU enable OUT (type 1)
    
    always_comb begin
        porta_in = porta_out;  // Start with output values
        
        // Override inputs based on DDR (0=input)
        if (!porta_ddr[6]) porta_in[6] = adb_in;         // ADB data in
        if (!porta_ddr[5]) porta_in[5] = 1'b1;           // System type (Egret controls power)
        if (!porta_ddr[2]) porta_in[2] = 1'b1;           // Keyboard power switch (on)
        if (!porta_ddr[1]) porta_in[1] = 1'b1;           // Chassis power switch
        if (!porta_ddr[0]) porta_in[0] = 1'b0;           // Control panel (LC style)
    end
    
    // Port B bit definitions (from MAME egret.cpp):
    // Bit 7: O - DFAC bit clock (I2C SCL)
    // Bit 6: ? - DFAC data I/O (I2C SDA)
    // Bit 5: ? - VIA shift register data (bidirectional)
    // Bit 4: O - VIA clock
    // Bit 3: I - VIA SYS_SESSION
    // Bit 2: I - VIA VIA_FULL
    // Bit 1: O - VIA XCEIVER SESSION
    // Bit 0: I - +5v sense
    
    always_comb begin
        portb_in = portb_out;  // Start with output values
        
        // Override inputs based on DDR
        if (!portb_ddr[5]) portb_in[5] = via_data_bit;   // VIA data
        if (!portb_ddr[3]) portb_in[3] = sys_session;    // VIA sys_session
        if (!portb_ddr[2]) portb_in[2] = via_full;       // VIA full flag
        if (!portb_ddr[0]) portb_in[0] = 1'b1;           // +5V present
    end
    
    // Port C bit definitions (from MAME egret.cpp):
    // Bit 3: O - 680x0 reset
    // Bit 2: ? - 680x0 IPL 2 (bidirectional)
    // Bit 1: ? - Trickle sense (if Egret controls PSU)
    // Bit 0: ? - Pulled up to +5V (if Egret controls PSU)
    
    always_comb begin
        portc_in = portc_out;  // Start with output values
        
        // For Egret-controlled power (LC style)
        if (!portc_ddr[1]) portc_in[1] = 1'b1;  // Trickle sense
        if (!portc_ddr[0]) portc_in[0] = 1'b1;  // Pulled to +5V
    end
    
    //==========================================================================
    // Output Signal Mapping
    //==========================================================================
    
    // ADB control (Port A bit 7, inverted because it drives a pull-down MOSFET)
    assign adb_out = ~porta_out[7];
    
    // DFAC control (Port A bit 4, Port B bits 7 and 6)
    assign dfac_latch = porta_out[4];
    assign dfac_scl = portb_out[7];
    assign dfac_sda = portb_out[6];
    
    // 68020 reset (Port C bit 3)
    assign reset_out = portc_out[3];
    
    // VIA communication (Port B)
    assign via_data_bit = portb_out[5];
    assign via_clock_bit = portb_out[4];
    assign xcvr_session = portb_out[1];
    
    // For now, stub out the VIA communication
    // TODO: Implement proper VIA shift register protocol
    assign sys_session = 1'b0;
    assign via_full = 1'b0;
    
    //==========================================================================
    // VIA Communication Logic (stub for now)
    // This needs to implement the actual VIA shift register protocol
    // to communicate with the main Mac VIA
    //==========================================================================
    
    // The VIA communication protocol:
    // - Egret uses Port B bit 5 for data, bit 4 for clock
    // - It implements a shift register protocol with the Mac's VIA
    // - sys_session and via_full are handshake signals
    // - xcvr_session controls the direction
    
    // TODO: This needs to be connected to your existing VIA interface
    // For now, just pass through zeros
    assign via_data_out = 8'h00;

endmodule