/*
	($000000 - $03FFFF) RAM  4MB, or Overlay ROM 4MB
	
	($400000 - $4FFFFF) ROM 1MB
		64K Mac 128K/512K ROM is $400000 - $40FFFF
		128K Mac 512Ke/Plus ROM is $400000 - $41FFFF
		If ROM is mirrored when A17 is 1, then SCSI is assumed to be unavailable

	($580000 - $580FFF) SCSI (Mac Plus only, not implemented here)

	($600000 - $7FFFFF) Overlay RAM 2MB

	($9FFFF8 - $BFFFFF) SCC

	($DFE1FF - $DFFFFF) IWM

	($EFE1FE - $EFFFFE) VIA

	($F00000 - $F00005) memory phase read test -> PseudoVIA / RBV for LC

	($F80000 - $FFFFEF) space for test software -> VRAM for LC (0xF40000)

	($FFFFF0 - $FFFFFF) interrupt vectors
*/

module addrDecoder(
	input [1:0] configROMSize,
	input [23:0] address,
	input _cpuAS,
	input memoryOverlayOn,
	output reg selectRAM,
	output reg selectROM,
	output reg selectSCSI,
	output reg selectSCC,
	output reg selectIWM,
	output reg selectVIA,
	output reg selectSEOverlay,
	output reg selectVideoROM,

	// Mac LC specific
	output reg selectPseudoVIA,
	output reg selectCLUT,
	output reg selectVRAM,
	output reg selectASC,
	output reg selectRAMDAC
);

	always @(*) begin
		selectRAM = 0;
		selectROM = 0;
		selectSCSI = 0;
		selectSCC = 0;
		selectIWM = 0;
		selectVIA = 0;
		selectSEOverlay = 0;
		selectVideoROM = 0;

		selectPseudoVIA = 0;
		selectCLUT = 0;
		selectVRAM = 0;
		selectASC = 0;
		selectRAMDAC = 0;

		if (configROMSize[1]) begin // Mac LC Mode (V8 Chip Map)
			casez (address[23:20])
				4'b0000: begin // 0x000000 - 0x0FFFFF
					if (memoryOverlayOn)
						selectROM = !_cpuAS; // Mirror ROM at 0x0 at boot
					else
						selectRAM = !_cpuAS;
				end
				4'b0001, 4'b0010, 4'b0011,
				4'b0100, 4'b0101, 4'b0110, 4'b0111,
				4'b1000, 4'b1001: begin // 0x100000 - 0x9FFFFF
					selectRAM = !_cpuAS;
				end
				4'b1010: begin // 0xA00000 - 0xAFFFFF
					selectROM = !_cpuAS;
				end
				4'b0101: begin // 0x500000 - 0x5FFFFF
					// VIA1: 0x500000 - 0x501FFF
					if (address[19:13] == 7'h00) selectVIA = !_cpuAS;

					// ASC: 0x514000 - 0x515FFF
					else if (address[19:13] == 7'h0A) selectASC = !_cpuAS;

					// RAMDAC (Ariel): 0x524000 - 0x525FFF
					else if (address[19:13] == 7'h12) selectRAMDAC = !_cpuAS;

					// PseudoVIA: 0x526000 - 0x527FFF
					else if (address[19:13] == 7'h13) selectPseudoVIA = !_cpuAS;

					// VRAM: 0x540000 - 0x5BFFFF
					// High nibble 5. Second nibble 4,5,6,7,8,9,A,B.
					// Corresponds to bit patterns 01xx and 10xx in bits 19:16.
					// Simplified: (19=0, 18=1) OR (19=1, 18=0).
					else if ((address[19] == 0 && address[18] == 1) || (address[19] == 1 && address[18] == 0)) selectVRAM = !_cpuAS;

				end
				4'b1111: begin // 0xF00000 - 0xFFFFFF
					// SCC: 0xF04000 - 0xF05FFF (8KB)
					// Matches 0xF04xxx and 0xF05xxx. Bits 19:13 must match 0x04 >> 1 = 0x02?
					// 0x04 = 0000 0100. 0x05 = 0000 0101.
					// Bit 12 varies. 19:13 is constant.
					// 0x04 >> 1 = 0000 0010 (0x02).
					if (address[19:13] == 7'h02) selectSCC = !_cpuAS;

					// SCSI DRQ: 0xF06000 - 0xF07FFF (8KB)
					// 0x06, 0x07. 19:13 == 0x03.
					else if (address[19:13] == 7'h03) selectSCSI = !_cpuAS; // Map DRQ to SCSI for now

					// SCSI Control: 0xF10000 - 0xF11FFF (8KB)
					// 0x10, 0x11. 19:13 == 0x08.
					else if (address[19:13] == 7'h08) selectSCSI = !_cpuAS;

					// SCSI DRQ (Alt): 0xF12000 - 0xF13FFF (8KB)
					// 0x12, 0x13. 19:13 == 0x09.
					else if (address[19:13] == 7'h09) selectSCSI = !_cpuAS;

					// SWIM (IWM): 0xF16000 - 0xF17FFF (8KB)
					// 0x16, 0x17. 19:13 == 0x0B.
					else if (address[19:13] == 7'h0B) selectIWM = !_cpuAS;

					// CLUT (from previous context, keep if needed or mapped to RAMDAC?)
					// User said RAMDAC is Ariel.
					// CLUT in previous context was at F02000.
					// If not in the new list, maybe ignore or keep?
					// I'll keep it disabled unless we need it, but the user list is authoritative.
					// "RAMDAC ... Ariel Palette Chip".
					// So I assume RAMDAC covers palette operations.
				end
			endcase

		end else begin // Legacy Mode
			casez (address[23:20])
				4'b00??: begin //00 0000 - 3F FFFF
					if (memoryOverlayOn == 0)
						selectRAM = !_cpuAS;
					else begin
						if (address[23:20] == 0) begin
							// Mac Plus: repeated images of overlay ROM only extend to $0F0000
							// Mac 512K: more repeated ROM images at $020000-$02FFFF
							// Mac SE:   overlay ROM at $00 0000 - $0F FFFF
							selectROM = !_cpuAS;
						end
					end
				end
				4'b0100: begin //40 0000 - 4F FFFF
					if(address[17] == 1'b0)   // <- this detects SCSI (on Plus)!!!
						selectROM = !_cpuAS;
					selectSEOverlay = !_cpuAS;
				end
				4'b0101: begin //50 000 - 5F FFFF
					if (address[19]) // 58 000 - 5F FFFF
						selectSCSI = !_cpuAS;
					selectSEOverlay = !_cpuAS;
				end
				4'b0110:
					if (memoryOverlayOn)
						selectRAM = !_cpuAS;
				4'b10?1:
					selectSCC = !_cpuAS;
				4'b1100: // C0 000 - CF FFF
					if (!configROMSize[1])
						selectIWM = !_cpuAS;
				4'b1101:
					selectIWM = !_cpuAS;
				4'b1110: // E0 0000 - EF FFFF
					if (address[19]) // E8 000 - EF FFF
						selectVIA = !_cpuAS;
					else // E0 0000 - E7 FFFF
						selectVideoROM = !_cpuAS;
				default:
					; // select nothing
			endcase
		end
	end
endmodule
