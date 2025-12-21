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
	output reg selectVRAM
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
				if(configROMSize[1] || address[17] == 1'b0)   // <- this detects SCSI (on Plus)!!!
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
			4'b1111: begin // F0 0000 - FF FFFF
				// Mac LC Specifics
				// VRAM at 0xF40000
				if (address[23:16] == 8'hF4)
					selectVRAM = !_cpuAS;
				// Pseudo-VIA at 0xF00000
				else if (address[23:16] == 8'hF0) begin
					// Let's carve out a space for CLUT if needed.
					// Assuming PseudoVIA occupies minimal space.
					// User said "recognize LC-specific memory ranges (VRAM, Pseudo-VIA, CLUT)."
					// Let's put CLUT at F02000 (arbitrary, as discussed)
					if (address[15:12] == 4'h2) // F0 2xxx
						selectCLUT = !_cpuAS;
					else
						selectPseudoVIA = !_cpuAS;
				end
			end
			default:
				; // select nothing
		endcase
	end
endmodule
