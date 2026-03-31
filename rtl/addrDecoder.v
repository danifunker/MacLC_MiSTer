/*
    Mac LC Memory Map (V8 System ASIC)
    Based on MAME v8.cpp and maclc.cpp

    Address masking: CPU uses global_mask(0x80ffffff) - bits 30-24 are ignored
    V8 internal addresses are offset by 0xA00000 for CPU address space

    ($000000 - $9FFFFF) RAM up to 10MB
        First 2MB motherboard RAM always at $800000-$9FFFFF
        SIMM RAM starts at $000000
        At boot, ROM is overlaid here until first ROM area access

    ($A00000 - $AFFFFF) ROM 512KB-1MB
        Reading from this area disables the overlay

    ($F00000 - $F01FFF) VIA1
        The VIA is on the upper byte of the data bus, so use even-addressed byte accesses only.
        16 VIA registers with 512-byte stride (A12-A9 select register)

    ($F04000 - $F05FFF) SCC
        Serial Communication Controller
        2-bit register addressing (A1-A0)

    ($F06000 - $F07FFF) SCSI DRQ
        Pseudo-DMA data transfer window

    ($F10000 - $F11FFF) SCSI
        NCR5380 registers
        Register = (offset >> 3) & 0xF

    ($F12000 - $F13FFF) SCSI DRQ
        Additional pseudo-DMA window

    ($F14000 - $F15FFF) ASC
        Apple Sound Chip (4-channel audio)
        Not yet implemented

    ($F16000 - $F17FFF) SWIM
        Floppy controller
        Register = (offset >> 8) & 0xF

    ($F24000 - $F25FFF) Ariel RAMDAC
        Video palette/DAC

    ($F26000 - $F27FFF) PseudoVIA
        GPIO and interrupt controller
        Provides VBlank and slot interrupts

    ($F40000 - $FBFFFF) VRAM
        512KB video RAM
*/

module addrDecoder(
    input [23:0] address,
    input _cpuAS,
    input _cpuRW,
    input memoryOverlayOn,
    input [7:0] ram_config,  // V8 RAM config: bits[7:6] = SIMM size

    output reg selectRAM,
    output reg selectROM,
    output reg selectSCSI,
    output reg selectSCC,
    output reg selectIWM,
    output reg selectASC,
    output reg selectVIA,

    // Mac LC Specific Selects
    output reg selectAriel,
    output reg selectPseudoVIA,
    output reg selectVRAM,
    output reg selectUnmapped
);

    // Decode SIMM byte size from ram_config[7:6]
    wire [23:0] simm_byte_size = (ram_config[7:6] == 2'b00) ? 24'h000000 :  // 0MB
                                  (ram_config[7:6] == 2'b01) ? 24'h200000 :  // 2MB
                                  (ram_config[7:6] == 2'b10) ? 24'h400000 :  // 4MB
                                                                24'h800000;   // 8MB

    // Valid RAM ranges:
    //   SIMM:        $000000 to simm_byte_size-1 (only if SIMM present)
    //   Motherboard: $800000-$9FFFFF (always 2MB)
    wire in_simm_range = (address[23:0] < simm_byte_size);
    wire in_motherboard_range = (address[23:21] == 3'b100);  // $800000-$9FFFFF

    always @(*) begin
        // Defaults - active low accent for active state
        selectRAM = 0;
        selectROM = 0;
        selectSCSI = 0;
        selectSCC = 0;
        selectIWM = 0;
        selectASC = 0;
        selectVIA = 0;
        selectAriel = 0;
        selectPseudoVIA = 0;
        selectVRAM = 0;
        selectUnmapped = 0;

        if (!_cpuAS) begin
            if (!_cpuRW) begin
                // $display("AD: WRITE addr=%h fc=%d @%0t", address, address[23:21], $time); // Wait! I'll use the proper FC signal later
            end
            // ==========================================================
            // Mac LC (V8) Memory Map - CPU Addresses
            // ==========================================================

            // --- ROM ($A00000 - $AFFFFF) ---
            if (address[23:20] == 4'hA) begin
                selectROM = 1;
            end

            // --- RAM or Overlay ROM ($000000 - $9FFFFF) ---
            else if (address[23:20] < 4'hA) begin
                if (memoryOverlayOn && _cpuRW) begin
                    // Overlay active: ROM appears at $000000 for READS
                    selectROM = 1;
                end else if (in_simm_range || in_motherboard_range) begin
                    // Normal operation: RAM only where it physically exists
                    selectRAM = 1;
                end else begin
                    // Address in $000000-$9FFFFF but no RAM here
                    selectUnmapped = 1;
                end
            end

            // --- Peripheral I/O ($F00000 - $FFFFFF) ---
            else if (address[23:20] == 4'hF) begin
                casez (address[19:12])
                    // VIA1: $F00000-$F01FFF
                    8'b0000_00??: selectVIA = 1;

                    // SCC: $F04000-$F05FFF
                    8'b0000_010?: selectSCC = 1;

                    // SCSI DRQ: $F06000-$F07FFF
                    8'b0000_011?: selectSCSI = 1;

                    // SCSI: $F10000-$F11FFF
                    8'b0001_000?: selectSCSI = 1;

                    // SCSI DRQ: $F12000-$F13FFF
                    8'b0001_001?: selectSCSI = 1;

                    // ASC: $F14000-$F15FFF
                    8'b0001_010?: selectASC = 1;

                    // SWIM/IWM: $F16000-$F17FFF
                    8'b0001_011?: selectIWM = 1;

                    // Ariel RAMDAC: $F24000-$F25FFF
                    8'b0010_010?: selectAriel = 1;

                    // PseudoVIA: $F26000-$F27FFF
                    8'b0010_011?: selectPseudoVIA = 1;

                    // VRAM: $F40000-$FBFFFF
                    // $F4xxxx = 0100, $F5xxxx = 0101, $F6xxxx = 0110, $F7xxxx = 0111
                    // $F8xxxx = 1000, $F9xxxx = 1001, $FAxxxx = 1010, $FBxxxx = 1011
                    8'b01??_????: selectVRAM = 1;  // $F40000-$F7FFFF
                    8'b10??_????: selectVRAM = 1;  // $F80000-$FBFFFF

                    default: selectUnmapped = 1;
                endcase
            end
            // Addresses $B00000-$EFFFFF are unmapped
            else begin
                selectUnmapped = 1;
            end
        end
    end
endmodule
