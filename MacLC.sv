//============================================================================
//  Macintosh LC
//
//  Based on MacPlus core by Sorgelig
//  Copyright (C) 2025-2026 Dani Sarfati
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output   [7:0] VGA_R,
	output   [7:0] VGA_G,
	output   [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER, 
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);
	assign ADC_BUS  = 'Z;
	assign USER_OUT = '1;

	assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;
	assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

	assign LED_USER  = dio_download || (disk_act ^ |diskMotor);
	assign LED_DISK  = 0;
	assign LED_POWER = 0;
	assign BUTTONS   = 0;
	assign VGA_SCALER= 0;
	assign VGA_DISABLE = 0;
	assign HDMI_FREEZE = 0;
	assign HDMI_BLACKOUT = 0;
	assign HDMI_BOB_DEINT = 0;

	wire [1:0] ar = status[8:7];
	video_freak video_freak
	(
		.*,
		.VGA_DE_IN(VGA_DE),
		.VGA_DE(),

		.ARX((!ar) ? 12'd256 : (ar - 1'd1)),
		.ARY((!ar) ? 12'd171 : 12'd0),
		.CROP_SIZE(0),
		.CROP_OFF(0),
		.SCALE(status[12:11])
	);
	
	`include "build_id.v"
	localparam CONF_STR = {
		"MACLC;UART115200;",
		"-;",
		"F1,DSK,Mount Pri Floppy;",
		"F2,DSK,Mount Sec Floppy;",
		"-;",
		"SC0,IMGVHD,Mount SCSI-6;",
		"SC1,IMGVHD,Mount SCSI-5;",
		"-;",
		"O78,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
		"OBC,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
		"-;",
		"OFG,Video Mode,4bpp,1bpp,2bpp,8bpp,16bpp;",
		"O1011,Monitor,512x384 12in RGB,640x480 VGA,Portrait;",
		"-;",
		"ODE,CPU,68020;",
		"O4,Memory,2MB,10MB;",
		"O6,Palette Test,Off,On;",
		"-;",
		"R0,Reset & Apply CPU+Memory;",
		"V,v",`BUILD_DATE
	};

	////////////////////   CLOCKS   ///////////////////

	wire clk_sys, clk_mem;
	wire pll_locked;

	pll pll
	(
		.refclk(CLK_50M),
		.outclk_0(clk_mem),
		.outclk_1(clk_sys),
		.locked(pll_locked)
	);

	reg       status_mem = 1'b1;
	localparam [1:0] status_cpu = 2'b10; // 68020
	reg       n_reset = 0;
	// Mac LC always runs at C15M (~15.67 MHz) - use 16 MHz clock enables
	always @(posedge clk_sys) begin
		reg [15:0] rst_cnt;

		if (clk8_en_p) begin
			// various sources can reset the mac
			// NOTE: Do NOT include ~_cpuReset_o here — the CPU executes the RESET
			// instruction during boot to reset peripherals, which would cause an
			// infinite reset loop if fed back to the system reset.
			if(~pll_locked || status[0] || buttons[1] || RESET) begin
				rst_cnt <= '1;
				n_reset <= 0;
			end
			else if(rst_cnt) begin
				rst_cnt    <= rst_cnt - 1'd1;
				status_mem <= status[4];
			end
			else begin
				n_reset <= 1;
			end
		end
	end

	///////////////////////////////////////////////////

	localparam SCSI_DEVS = 2;

	// the status register is controlled by the on screen display (OSD)
	wire [31:0] status;
	wire  [1:0] buttons;
	wire [31:0] sd_lba[SCSI_DEVS];
	wire  [SCSI_DEVS-1:0] sd_rd;
	wire  [SCSI_DEVS-1:0] sd_wr;
	wire  [SCSI_DEVS-1:0] sd_ack;
	wire            [7:0] sd_buff_addr;
	wire           [15:0] sd_buff_dout;
	wire           [15:0] sd_buff_din[SCSI_DEVS];
	wire                  sd_buff_wr;
	wire  [SCSI_DEVS-1:0] img_mounted;
	wire           [63:0] img_size;
	wire        ioctl_write;
	reg         ioctl_wait = 0;
	wire [10:0] ps2_key;
	wire [24:0] ps2_mouse;
	wire        capslock;

	wire [24:0] ioctl_addr;
	wire [15:0] ioctl_data;

	wire [32:0] TIMESTAMP;

	hps_io #(.CONF_STR(CONF_STR), .VDNUM(SCSI_DEVS), .WIDE(1)) hps_io
	(
		.clk_sys(clk_sys),
		.HPS_BUS(HPS_BUS),

		.buttons(buttons),
		.status(status),

		.sd_lba(sd_lba),
		.sd_rd(sd_rd),
		.sd_wr(sd_wr),
		.sd_ack(sd_ack),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr),
		
		.img_mounted(img_mounted),
		.img_size(img_size),

		.ioctl_download(dio_download),
		.ioctl_index(dio_index),
		.ioctl_wr(ioctl_write),
		.ioctl_addr(ioctl_addr),
		.ioctl_dout(ioctl_data),
		.ioctl_wait(ioctl_wait),

		.TIMESTAMP(TIMESTAMP),

		.ps2_key(ps2_key),
		.ps2_kbd_led_use(3'b001),
		.ps2_kbd_led_status({2'b00, capslock}),

		.ps2_mouse(ps2_mouse)
	);

	assign CLK_VIDEO = clk_sys;
	assign CE_PIXEL  = v8_ce_pix;

	// Test pattern mode: 0=Off, 2=Palette Test (uses Ariel RAMDAC lookup with h_count as index)
	wire palette_test = status[6];

	// Debug indicator: pixel counter synced to DE
	reg [9:0] dbg_x, dbg_y;
	reg dbg_de_prev;
	always @(posedge clk_sys) begin
		dbg_de_prev <= v8_de;
		if (v8_ce_pix) begin
			if (v8_de) begin
				dbg_x <= dbg_x + 1'd1;
			end else begin
				if (dbg_de_prev && !v8_de)
					dbg_y <= dbg_y + 1'd1;
				dbg_x <= 0;
			end
			if (v8_vsync)
				dbg_y <= 0;
		end
	end
	// VIA SR debug signals from dataController
	wire [2:0]  via_sr_dbg_bit_cnt;
	wire        via_sr_dbg_edge_pending;
	wire        via_sr_dbg_fall_pending;
	wire [7:0]  via_sr_dbg_shift_reg;
	wire        via_sr_dbg_active;
	wire        via_sr_dbg_dir;
	wire        via_sr_dbg_cb1;
	wire        via_sr_dbg_cb2;

	// Egret debug signals from dataController
	wire        egret_dbg_running;
	wire        egret_dbg_port_test_done;
	wire        egret_dbg_handshake_done;
	wire        egret_dbg_treq;
	wire        egret_dbg_tip;
	wire        egret_dbg_byteack;
	wire        egret_dbg_reset_680x0;
	wire        egret_dbg_cpu_reset_out;

	// Latch SR transfer count (increments each time shift_active goes 1->0)
	reg [7:0] sr_xfer_count = 0;
	reg sr_active_prev = 0;
	always @(posedge clk_sys) begin
		sr_active_prev <= via_sr_dbg_active;
		if (sr_active_prev && !via_sr_dbg_active)
			sr_xfer_count <= sr_xfer_count + 1'd1;
	end

	// === On-screen debug overlay ===
	// Layout (top-left corner, each block 8x8 pixels):
	//
	// Row 0 (y=0..7):   Ariel indicator (50x8) - Yellow=no writes, Blue=written
	// Row 1 (y=10..17): SR shift_reg bits [7:0] - Green=1, Dark=0
	// Row 2 (y=20..27): bit_cnt [2:0] + active + dir + CB1 + CB2 + edge_pend + fall_pend
	// Row 3 (y=30..37): sr_xfer_count [7:0] - Blue=1, Dark=0
	// Row 4 (y=42..49): Egret status: running + port_test + handshake + TREQ + TIP + BYTEACK + reset_680x0 + cpuReset
	// Row 5 (y=54..61): Egret cycle counter [7:0] - Magenta=1, Dark=0 (proves HC05 is executing)
	// Row 6 (y=66..73): 68K alive counter [7:0] - Orange=1, Dark=0 (proves 68K is fetching)
	// Row 7 (y=78..85): 68K addr[23:16] - White=1, Dark=0 (shows memory region being accessed)

	wire debug_ariel  = (dbg_x < 10'd50) && (dbg_y < 10'd8);
	wire debug_sr_reg = (dbg_y >= 10'd10) && (dbg_y < 10'd18) && (dbg_x < 10'd64);
	wire debug_status = (dbg_y >= 10'd20) && (dbg_y < 10'd28) && (dbg_x < 10'd72);
	wire debug_xfer   = (dbg_y >= 10'd30) && (dbg_y < 10'd38) && (dbg_x < 10'd64);
	wire debug_egret  = (dbg_y >= 10'd42) && (dbg_y < 10'd50) && (dbg_x < 10'd64);
	wire debug_ecyc   = (dbg_y >= 10'd54) && (dbg_y < 10'd62) && (dbg_x < 10'd64);
	wire debug_68k    = (dbg_y >= 10'd66) && (dbg_y < 10'd74) && (dbg_x < 10'd64);
	wire debug_68addr = (dbg_y >= 10'd78) && (dbg_y < 10'd86) && (dbg_x < 10'd64);
	wire debug_any    = debug_ariel || debug_sr_reg || debug_status || debug_xfer
	                  || debug_egret || debug_ecyc || debug_68k || debug_68addr;

	// Which bit of shift_reg to show (bit 7 on left, bit 0 on right)
	wire [2:0] sr_bit_idx = 3'd7 - dbg_x[5:3];
	wire sr_bit_val = via_sr_dbg_shift_reg[sr_bit_idx];

	// Status row: bit_cnt(3) + active + dir + CB1 + CB2 + edge_pend + fall_pend = 9 blocks
	wire [3:0] status_block = dbg_x[6:3]; // which 8px block
	wire status_val = (status_block == 0) ? via_sr_dbg_bit_cnt[2] :
	                  (status_block == 1) ? via_sr_dbg_bit_cnt[1] :
	                  (status_block == 2) ? via_sr_dbg_bit_cnt[0] :
	                  (status_block == 3) ? via_sr_dbg_active :
	                  (status_block == 4) ? via_sr_dbg_dir :
	                  (status_block == 5) ? via_sr_dbg_cb1 :
	                  (status_block == 6) ? via_sr_dbg_cb2 :
	                  (status_block == 7) ? via_sr_dbg_edge_pending :
	                                        via_sr_dbg_fall_pending;

	// Xfer count bits
	wire [2:0] xfer_bit_idx = 3'd7 - dbg_x[5:3];
	wire xfer_bit_val = sr_xfer_count[xfer_bit_idx];

	// Egret status row: 8 blocks, each 8px wide
	// Block 0: running (Green=yes)
	// Block 1: port_test_done (Green=done)
	// Block 2: handshake_done (Green=done)
	// Block 3: TREQ (Red=asserted)
	// Block 4: TIP (Yellow=active/low)
	// Block 5: BYTEACK (Cyan=active)
	// Block 6: reset_680x0 (Red=holding reset, Green=released)
	// Block 7: _cpuReset (Green=running, Red=held)
	wire [2:0] egret_block = dbg_x[5:3];
	wire egret_val = (egret_block == 0) ? egret_dbg_running :
	                 (egret_block == 1) ? egret_dbg_port_test_done :
	                 (egret_block == 2) ? egret_dbg_handshake_done :
	                 (egret_block == 3) ? egret_dbg_treq :
	                 (egret_block == 4) ? ~egret_dbg_tip :       // TIP is active LOW, show bright when active
	                 (egret_block == 5) ? egret_dbg_byteack :
	                 (egret_block == 6) ? egret_dbg_reset_680x0 :
	                                      egret_dbg_cpu_reset_out;

	// Egret cycle counter - increments each frame to prove HC05 is running
	// We sample a free-running counter driven by egret_dbg_running
	reg [23:0] egret_alive_cnt = 0;
	always @(posedge clk_sys) begin
		if (egret_dbg_running)
			egret_alive_cnt <= egret_alive_cnt + 1'd1;
	end
	wire [7:0] egret_alive_byte = egret_alive_cnt[23:16]; // slow-changing bits visible on screen
	wire [2:0] ecyc_bit_idx = 3'd7 - dbg_x[5:3];
	wire ecyc_bit_val = egret_alive_byte[ecyc_bit_idx];

	// 68K activity counter - increments on each bus cycle (_cpuAS falling edge)
	reg [23:0] cpu_alive_cnt = 0;
	reg cpu_as_prev = 1;
	always @(posedge clk_sys) begin
		cpu_as_prev <= _cpuAS;
		if (cpu_as_prev && !_cpuAS)  // AS falling edge = new bus cycle
			cpu_alive_cnt <= cpu_alive_cnt + 1'd1;
	end
	wire [7:0] cpu_alive_byte = cpu_alive_cnt[23:16]; // slow-changing bits
	wire [2:0] cpu68_bit_idx = 3'd7 - dbg_x[5:3];
	wire cpu68_bit_val = cpu_alive_byte[cpu68_bit_idx];

	// 68K address upper byte - latched on AS falling edge
	reg [7:0] cpu_addr_upper = 0;
	always @(posedge clk_sys) begin
		if (cpu_as_prev && !_cpuAS)
			cpu_addr_upper <= cpuAddr[23:16];
	end
	wire [2:0] addr_bit_idx = 3'd7 - dbg_x[5:3];
	wire addr_bit_val = cpu_addr_upper[addr_bit_idx];

	// Debug pixel color
	reg [7:0] dbg_r, dbg_g, dbg_b;
	always @(*) begin
		dbg_r = 8'h10; dbg_g = 8'h10; dbg_b = 8'h10; // dark background
		if (debug_ariel) begin
			// Yellow = no Ariel writes, Blue = Ariel written
			dbg_r = ariel_written ? 8'h00 : 8'hFF;
			dbg_g = ariel_written ? 8'h00 : 8'hFF;
			dbg_b = ariel_written ? 8'hFF : 8'h00;
		end else if (debug_sr_reg) begin
			// Shift register bits: Green = 1
			dbg_r = 8'h00; dbg_g = sr_bit_val ? 8'hFF : 8'h30; dbg_b = 8'h00;
		end else if (debug_status) begin
			// Color-coded status indicators
			case (status_block)
				0,1,2: begin // bit_cnt: White
					dbg_r = status_val ? 8'hFF : 8'h30;
					dbg_g = status_val ? 8'hFF : 8'h30;
					dbg_b = status_val ? 8'hFF : 8'h30;
				end
				3: begin // active: Cyan
					dbg_r = 8'h00;
					dbg_g = status_val ? 8'hFF : 8'h30;
					dbg_b = status_val ? 8'hFF : 8'h30;
				end
				4: begin // dir: Magenta
					dbg_r = status_val ? 8'hFF : 8'h30;
					dbg_g = 8'h00;
					dbg_b = status_val ? 8'hFF : 8'h30;
				end
				5: begin // CB1: Yellow
					dbg_r = status_val ? 8'hFF : 8'h30;
					dbg_g = status_val ? 8'hFF : 8'h30;
					dbg_b = 8'h00;
				end
				6: begin // CB2: Red
					dbg_r = status_val ? 8'hFF : 8'h30;
					dbg_g = 8'h00;
					dbg_b = 8'h00;
				end
				7: begin // edge_pending: Green
					dbg_r = 8'h00;
					dbg_g = status_val ? 8'hFF : 8'h30;
					dbg_b = 8'h00;
				end
				default: begin // fall_pending: Orange
					dbg_r = status_val ? 8'hFF : 8'h30;
					dbg_g = status_val ? 8'h80 : 8'h18;
					dbg_b = 8'h00;
				end
			endcase
		end else if (debug_xfer) begin
			// Transfer count: Blue = 1
			dbg_r = 8'h00; dbg_g = 8'h00; dbg_b = xfer_bit_val ? 8'hFF : 8'h30;
		end else if (debug_egret) begin
			// Egret status indicators - color per block
			case (egret_block)
				0: begin // running: Green
					dbg_r = 8'h00;
					dbg_g = egret_val ? 8'hFF : 8'h30;
					dbg_b = 8'h00;
				end
				1: begin // port_test_done: Green
					dbg_r = 8'h00;
					dbg_g = egret_val ? 8'hFF : 8'h30;
					dbg_b = 8'h00;
				end
				2: begin // handshake_done: Green
					dbg_r = 8'h00;
					dbg_g = egret_val ? 8'hFF : 8'h30;
					dbg_b = 8'h00;
				end
				3: begin // TREQ: Red=asserted
					dbg_r = egret_val ? 8'hFF : 8'h30;
					dbg_g = 8'h00;
					dbg_b = 8'h00;
				end
				4: begin // TIP active: Yellow
					dbg_r = egret_val ? 8'hFF : 8'h30;
					dbg_g = egret_val ? 8'hFF : 8'h30;
					dbg_b = 8'h00;
				end
				5: begin // BYTEACK: Cyan
					dbg_r = 8'h00;
					dbg_g = egret_val ? 8'hFF : 8'h30;
					dbg_b = egret_val ? 8'hFF : 8'h30;
				end
				6: begin // reset_680x0: Red=holding, Green=released
					dbg_r = egret_val ? 8'hFF : 8'h00;
					dbg_g = egret_val ? 8'h00 : 8'hFF;
					dbg_b = 8'h00;
				end
				default: begin // _cpuReset: Green=running, Red=held
					dbg_r = egret_val ? 8'h00 : 8'hFF;
					dbg_g = egret_val ? 8'hFF : 8'h00;
					dbg_b = 8'h00;
				end
			endcase
		end else if (debug_ecyc) begin
			// Egret alive counter: Magenta = 1 (should change over time if HC05 is running)
			dbg_r = ecyc_bit_val ? 8'hFF : 8'h30;
			dbg_g = 8'h00;
			dbg_b = ecyc_bit_val ? 8'hFF : 8'h30;
		end else if (debug_68k) begin
			// 68K alive counter: Orange = 1 (should change if CPU is fetching)
			dbg_r = cpu68_bit_val ? 8'hFF : 8'h30;
			dbg_g = cpu68_bit_val ? 8'h80 : 8'h18;
			dbg_b = 8'h00;
		end else if (debug_68addr) begin
			// 68K address[23:16]: White = 1 (shows memory region)
			// Common values: 0x40=ROM, 0x00=RAM, 0x50=VIA, 0xF0=VRAM
			dbg_r = addr_bit_val ? 8'hFF : 8'h30;
			dbg_g = addr_bit_val ? 8'hFF : 8'h30;
			dbg_b = addr_bit_val ? 8'hFF : 8'h30;
		end
	end

	// Video Output
	assign VGA_R  = (debug_any && v8_de) ? dbg_r : v8_vga_r;
	assign VGA_G  = (debug_any && v8_de) ? dbg_g : v8_vga_g;
	assign VGA_B  = (debug_any && v8_de) ? dbg_b : v8_vga_b;
	assign VGA_DE = v8_de;
	assign VGA_VS = v8_vsync;
	assign VGA_HS = v8_hsync;
	assign VGA_F1 = 0;
	assign VGA_SL = 0;

	wire [10:0] audio;
	assign AUDIO_L = {audio[10:0], 5'b00000};
	assign AUDIO_R = {audio[10:0], 5'b00000};
	assign AUDIO_S = 1;
	assign AUDIO_MIX = 0;

	// Mac LC memory configuration
	// V8 RAM config byte (MAME encoding):
	//   Bits 7:6 = SIMM size (00=0MB, 01=2MB, 10=4MB, 11=8MB)
	//   Bit 5 = Motherboard (0=4MB, 1=2MB)
	//   Bit 2 = Always set on read (handled in pseudovia)
	// Mac LC (2MB soldered): 2MB=$24, 4MB=$64, 6MB=$A4, 10MB=$E4
	wire [7:0] configRAMSize = status[4] ? 8'hE4 : 8'h24; // 1=10MB (8MB SIMM+2MB board), 0=2MB (board only)
	wire [7:0] pvia_ram_config_out;   // Active RAM config from pseudovia
				  
	// Serial Ports
	wire serialOut;
	wire serialIn;
	wire serialCTS;
	wire serialRTS;

	// V8 Video system wires
	wire [21:0] v8_video_addr;
	wire v8_hsync, v8_vsync, v8_hblank, v8_vblank, v8_de;
	wire v8_ce_pix;
	wire [7:0] v8_vga_r, v8_vga_g, v8_vga_b;
	wire [7:0] ariel_pixel_addr;
	wire [23:0] ariel_palette_data;
	wire [7:0] ariel_reg_dout;
	wire selectAriel;      // From address decoder
	wire selectPseudoVIA;  // From address decoder
	wire selectVRAM;       // From address decoder
	wire [7:0] pseudovia_dout;
	wire pseudovia_irq;

	// GEMINI: Force serialIn to 1 (Idle) to prevent SCC Break detection loop in ROM
	// assign serialIn =  UART_RXD;
	assign serialIn = 1'b1; 
	assign UART_TXD = serialOut;
	assign UART_RTS = serialRTS ;
	assign UART_DTR = UART_DSR;


	// interconnects
	// CPU
	wire clk8, _cpuReset, _cpuReset_o, _cpuUDS, _cpuLDS, _cpuRW, _cpuAS;
	wire clk8_en_p, clk8_en_n;
	wire clk16_en_p, clk16_en_n;
	wire _cpuVMA, _cpuVPA, _cpuDTACK;
	wire E_rising, E_falling;
	wire [2:0] _cpuIPL;
	wire [2:0] cpuFC;
	wire [7:0] cpuAddrHi;
	wire [23:0] cpuAddr;
	wire [15:0] cpuDataOut;

	// RAM/ROM
	wire _romOE;
	wire _ramOE, _ramWE;
	wire _memoryUDS, _memoryLDS;
	wire videoBusControl;
	wire dioBusControl;
	wire cpuBusControl;
	wire [22:0] memoryAddr;  // 23-bit SDRAM word address from address controller
	wire [15:0] memoryDataOut;
	wire memoryLatch;
	// Video latch: only pulse when memoryLatch AND in video bus cycle
	wire v8_video_latch = memoryLatch && videoBusControl;
	// peripherals
	wire vid_alt, loadPixels, pixelOut, _hblank, _vblank, hsync, vsync;
	wire memoryOverlayOn, selectSCSI, selectSCC, selectIWM, selectVIA, selectRAM, selectROM, selectSEOverlay, selectASC, selectUnmapped;
	wire [15:0] dataControllerDataOut;

	// audio
	wire snd_alt;
	wire loadSound;

	// floppy disk image interface
	wire dskReadAckInt;
	wire [21:0] dskReadAddrInt;
	wire dskReadAckExt;
	wire [21:0] dskReadAddrExt;

	// dtack generation for 16 MHz mode
	reg  dtack_en, cpuBusControl_d;
	always @(posedge clk_sys) begin
		if (!_cpuReset) begin
			dtack_en <= 0;
		end
		else begin
			cpuBusControl_d <= cpuBusControl;
			if (_cpuAS) dtack_en <= 0;
			if (!_cpuAS & ((!cpuBusControl_d & cpuBusControl) | (!selectROM & !selectRAM))) dtack_en <= 1;
		end
	end

	assign      _cpuVPA = (cpuFC == 3'b111) ? 1'b0 : ~(!_cpuAS && cpuAddr[23:21] == 3'b111);
	assign      _cpuDTACK = ~(!_cpuAS && cpuAddr[23:21] != 3'b111) | !dtack_en;
	wire        cpu_en_p      = clk16_en_p;
	wire        cpu_en_n      = clk16_en_n;
	assign      _cpuReset_o   = tg68_reset_n;
	assign      _cpuRW        = tg68_rw;
	assign      _cpuAS        = tg68_as_n;
	assign      _cpuUDS       = tg68_uds_n;
	assign      _cpuLDS       = tg68_lds_n;
	assign      E_falling     = tg68_E_falling;
	assign      E_rising      = tg68_E_rising;
	assign      _cpuVMA       = tg68_vma_n;
	assign      cpuFC[0]      = tg68_fc0;
	assign      cpuFC[1]      = tg68_fc1;
	assign      cpuFC[2]      = tg68_fc2;
	assign      cpuAddr[23:1] = tg68_a[23:1];
	assign      cpuDataOut    = tg68_dout;

	wire        tg68_rw;
	wire        tg68_as_n;
	wire        tg68_uds_n;
	wire        tg68_lds_n;
	wire        tg68_E_rising;
	wire        tg68_E_falling;
	wire        tg68_vma_n;
	wire        tg68_fc0;
	wire        tg68_fc1;
	wire        tg68_fc2;
	wire [15:0] tg68_dout;
	wire [31:0] tg68_a;
	wire        tg68_reset_n;
	
	tg68k tg68k (
		.clk        ( clk_sys      ),
		.reset      ( !_cpuReset ),
		.phi1       ( cpu_en_p  ),
		.phi2       ( cpu_en_n  ),
		.cpu        ( {status_cpu[1], |status_cpu} ),

		.dtack_n    ( _cpuDTACK  ),
		.rw_n       ( tg68_rw    ),
		.as_n       ( tg68_as_n  ),
		.uds_n      ( tg68_uds_n ),
		.lds_n      ( tg68_lds_n ),
		.fc         ( { tg68_fc2, tg68_fc1, tg68_fc0 } ),
		.reset_n    ( tg68_reset_n ),

		.E          (  ),
		.E_div      ( 1'b1 ),
		.E_PosClkEn ( tg68_E_falling ),
		.E_NegClkEn ( tg68_E_rising  ),
		.vma_n      ( tg68_vma_n ),
		.vpa_n      ( _cpuVPA ),

		.br_n       ( 1'b1    ),
		.bg_n       (  ),
				.bgack_n    ( 1'b1 ),
				.ipl        ( _cpuIPL ),
				.berr       ( cpuFC == 3'b111 ),
				.din        ( dataControllerDataOut ),
				.dout       ( tg68_dout ),
				.addr       ( tg68_a )
			);
	
	addrController_top ac0
	(
		.clk(clk_sys),
		.clk8(clk8),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.clk16_en_p(clk16_en_p),
		.clk16_en_n(clk16_en_n),
		.cpuAddr(cpuAddr),
		._cpuUDS(_cpuUDS),
		._cpuLDS(_cpuLDS),
		._cpuRW(_cpuRW),
		._cpuAS(_cpuAS),
		.ram_config(pvia_ram_config_out),
		.memoryAddr(memoryAddr),
		.memoryLatch(memoryLatch),
		._memoryUDS(_memoryUDS),
		._memoryLDS(_memoryLDS),
		._romOE(_romOE),
		._ramOE(_ramOE),
		._ramWE(_ramWE),
		.videoBusControl(videoBusControl),
		.dioBusControl(dioBusControl),
		.cpuBusControl(cpuBusControl),
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectSEOverlay(selectSEOverlay),
		.selectAriel(selectAriel),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM),
		.selectUnmapped(selectUnmapped),
		.hsync(hsync),
		.vsync(vsync),
		._hblank(_hblank),
		._vblank(_vblank),
		.loadPixels(loadPixels),
		.vid_alt(vid_alt),
		.v8_video_addr(v8_video_addr),
		.v8_hblank(v8_hblank),
		.v8_vblank(v8_vblank),
		.memoryOverlayOn(memoryOverlayOn),

		.snd_alt(snd_alt),
		.loadSound(loadSound),

		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt)
	);

	always @(posedge clk_sys) begin
		if (selectSEOverlay && !_cpuAS)
			$display("DC: selectSEOverlay ACTIVE (addr=%h) @%0t", cpuAddr, $time);
	end

	wire [1:0] diskEject;
	wire [1:0] diskMotor, diskAct;
	
	// Video Mode Selection Logic
	// 0=1bpp, 1=2bpp, 2=4bpp, 3=8bpp, 4=16bpp
	// Mapped from OSD (status[16:15]) for now:
	// DEBUG: Allow CPU to set video mode (via PseudoVIA)
	wire [2:0] v8_video_mode = pvia_video_config[2:0];
	/*
	wire [2:0] v8_video_mode = status[16:15] == 2'b00 ? 3'd2 : // 4bpp
							   status[16:15] == 2'b01 ? 3'd1 : // 2bpp
							   status[16:15] == 2'b10 ? 3'd0 : // 1bpp
							   status[16:15] == 2'b11 ? 3'd3 : // 8bpp
							   status[17] ? 3'd4 : 3'd2;       // 16bpp override
	*/

	// Monitor ID Selection
	wire [3:0] v8_monitor_id = status[11:10] == 2'b00 ? 4'h2 : // 512x384 12" RGB
							   status[11:10] == 2'b01 ? 4'h6 : // 640x480 VGA
							   4'h1;                           // Portrait

	ariel_ramdac ariel(
		.clk_sys(clk_sys),
		.reset(~n_reset),
		.reg_addr(cpuAddr[10:0]),
		.uds_n(_cpuUDS),
		.lds_n(_cpuLDS),
		.data_in(cpuDataOut[7:0]),
		.data_out(ariel_reg_dout),
		.we(selectAriel && !_cpuRW && cpuBusControl),
		.req(selectAriel && cpuBusControl),

		// The RAMDAC now takes the index from v8_video and returns RGB data
		// Palette test mode: override with h_count gradient to test palette independently of SDRAM
		.pixel_index(palette_test ? dbg_x[8:1] : ariel_pixel_addr),
		.rgb_out(ariel_palette_data),
		.ariel_written(ariel_written)
	);
	wire ariel_written;

	wire [7:0] pvia_video_config;
	wire [7:0] asc_data_out;
	wire asc_irq;

	pseudovia pvia(
		.clk_sys(clk_sys),
		.reset(~n_reset),
		.addr(cpuAddr[12:0]),
		.data_in(cpuDataOut[7:0]),
		.data_out(pseudovia_dout),
		.we(selectPseudoVIA && !_cpuRW && cpuBusControl),
		.req(selectPseudoVIA && cpuBusControl),
		.vblank_irq(v8_vblank),
		.slot_irq(1'b0),
		.asc_irq(asc_irq),
		.irq_out(pseudovia_irq),
		.ram_config(configRAMSize),
		.monitor_id(v8_monitor_id),
		.video_config(pvia_video_config),
		.ram_config_out(pvia_ram_config_out)
	);

	maclc_v8_video v8_video(
		.clk_sys(clk_sys),
		.clk8_en_p(clk8_en_p),
		.reset(~n_reset),
		
		// VRAM Interface (byte offset from VRAM start, translated in addrController)
		.video_addr(v8_video_addr),
		.video_data_in(sdram_do), // Data from SDRAM (valid when video_latch=1)
		.video_latch(v8_video_latch),
		
		// Configuration
		.video_mode(v8_video_mode),
		.monitor_id(v8_monitor_id),
		
		// Video Signals
		.hsync(v8_hsync),
		.vsync(v8_vsync),
		.hblank(v8_hblank),
		.vblank(v8_vblank),
		.vga_r(v8_vga_r),
		.vga_g(v8_vga_g),
		.vga_b(v8_vga_b),
		.de(v8_de),
		.ce_pix(v8_ce_pix),
		
		// Palette Interface (Connected to Ariel RAMDAC)
		.palette_addr(ariel_pixel_addr),
		.palette_data(ariel_palette_data)
	);

	asc asc_inst(
		.clk(clk_sys),
		.reset(~n_reset),
		.cs(selectASC),
		.addr(cpuAddr[11:0]),
		.data_in(cpuDataOut[7:0]),
		.data_out(asc_data_out),
		.we(!_cpuRW && cpuBusControl),
		.irq(asc_irq)
	);

	/*
	always @(posedge clk_sys) begin
		if (!_cpuAS && clk8_en_p) begin
			$display("DC: AS_active addr=%h fc=%d rw=%b @%0t", cpuAddr, cpuFC, _cpuRW, $time);
		end
	end
	*/

	// v8_vblank debug removed - fires every frame, too noisy

	reg memoryOverlayOn_prev;
	always @(posedge clk_sys) begin
		if (memoryOverlayOn != memoryOverlayOn_prev) begin
			$display("DC: memoryOverlayOn changed: %b @%0t", memoryOverlayOn, $time);
		end
		memoryOverlayOn_prev <= memoryOverlayOn;
	end

	dataController_top dataController (
		.clk32(clk_sys),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.E_rising(E_rising),
		.E_falling(E_falling),
		._systemReset(n_reset),
		.pseudovia_irq(pseudovia_irq),
		._cpuReset(_cpuReset), 
		._cpuIPL(_cpuIPL),
		._cpuUDS(_cpuUDS), 
		._cpuLDS(_cpuLDS), 
		._cpuRW(_cpuRW), 
		._cpuVMA(_cpuVMA),
		.cpuDataIn(cpuDataOut),
		.cpuDataOut(dataControllerDataOut), 	
		.cpuAddrRegHi(cpuAddr[12:9]),
		.cpuAddrRegMid(cpuAddr[6:4]),  // for SCSI
		.cpuAddrRegLo(cpuAddr[2:1]),		
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectASC(selectASC),
		.asc_data_in(asc_data_out),
		.selectSEOverlay(selectSEOverlay),
		.cpuBusControl(cpuBusControl),
		.videoBusControl(videoBusControl),
		.memoryDataOut(memoryDataOut),
		.memoryDataIn(sdram_do),
		.memoryLatch(memoryLatch),
		.selectAriel(selectAriel),
		.ariel_data_in(ariel_reg_dout),
		.selectPseudoVIA(selectPseudoVIA),
		.pseudovia_data_in(pseudovia_dout),
		.selectUnmapped(selectUnmapped),
		
		// peripherals
		.ps2_key(ps2_key), 
		.capslock(capslock),
		.ps2_mouse(ps2_mouse),
		// serial uart
		.serialIn(serialIn),
		.serialOut(serialOut),
		.serialCTS(serialCTS),
		.serialRTS(serialRTS),

		// rtc unix ticks
		.timestamp(TIMESTAMP),

		// video
		._hblank(_hblank),
		._vblank(_vblank), 
		.pixelOut(pixelOut),
		.loadPixels(loadPixels),
		.vid_alt(vid_alt),

		.memoryOverlayOn(memoryOverlayOn),

		.audioOut(audio),
		.snd_alt(snd_alt),
		.loadSound(loadSound),

		// floppy disk interface
		.insertDisk({dsk_ext_ins, dsk_int_ins}),
		.diskSides({dsk_ext_ds, dsk_int_ds}),
		.diskEject(diskEject),
		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.diskMotor(diskMotor),
		.diskAct(diskAct),

		// block device interface for scsi disk
		.img_mounted(img_mounted),
		.img_size(img_size[40:9]),
		.io_lba(sd_lba),
		.io_rd(sd_rd),
		.io_wr(sd_wr),
		.io_ack(sd_ack),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr),

		// VIA SR debug
		.via_sr_dbg_bit_cnt(via_sr_dbg_bit_cnt),
		.via_sr_dbg_edge_pending(via_sr_dbg_edge_pending),
		.via_sr_dbg_fall_pending(via_sr_dbg_fall_pending),
		.via_sr_dbg_shift_reg(via_sr_dbg_shift_reg),
		.via_sr_dbg_active(via_sr_dbg_active),
		.via_sr_dbg_dir(via_sr_dbg_dir),
		.via_sr_dbg_cb1(via_sr_dbg_cb1),
		.via_sr_dbg_cb2(via_sr_dbg_cb2),

		.egret_dbg_running(egret_dbg_running),
		.egret_dbg_port_test_done(egret_dbg_port_test_done),
		.egret_dbg_handshake_done(egret_dbg_handshake_done),
		.egret_dbg_treq(egret_dbg_treq),
		.egret_dbg_tip(egret_dbg_tip),
		.egret_dbg_byteack(egret_dbg_byteack),
		.egret_dbg_reset_680x0(egret_dbg_reset_680x0),
		.egret_dbg_cpu_reset_out(egret_dbg_cpu_reset_out)
	);

	reg disk_act;
	always @(posedge clk_sys) begin
		integer timeout = 0;

		if(timeout) begin
			timeout <= timeout - 1;
			disk_act <= 1;
		end else begin
			disk_act <= 0;
		end

		if(|diskAct) timeout <= 500000;
	end

	//////////////////////// DOWNLOADING ///////////////////////////

	// include ROM download helper
	wire dio_download;
	wire [23:0] dio_addr = ioctl_addr[24:1];
	wire  [7:0] dio_index;

	// good floppy image sizes are 819200 bytes and 409600 bytes
	reg dsk_int_ds, dsk_ext_ds;
	reg dsk_int_ss, dsk_ext_ss;  // single sided image inserted

	// any known type of disk image inserted?
	wire dsk_int_ins = dsk_int_ds || dsk_int_ss;
	wire dsk_ext_ins = dsk_ext_ds || dsk_ext_ss;
	// at the end of a download latch file size
	// diskEject is set by macos on eject
	always @(posedge clk_sys) begin
		reg old_down;
		old_down <= dio_download;
		if(old_down && ~dio_download && dio_index == 1) begin
			dsk_int_ds <= (dio_addr == 409600);
			// double sides disk, addr counts words, not bytes
			dsk_int_ss <= (dio_addr == 204800);   // single sided disk
		end

		if(diskEject[0]) begin
			dsk_int_ds <= 0;
			dsk_int_ss <= 0;
		end
	end	

	always @(posedge clk_sys) begin
		reg old_down;

		old_down <= dio_download;
		if(old_down && ~dio_download && dio_index == 2) begin
			dsk_ext_ds <= (dio_addr == 409600);
			// double sided disk, addr counts words, not bytes
			dsk_ext_ss <= (dio_addr == 204800);   // single sided disk
		end

		if(diskEject[1]) begin
			dsk_ext_ds <= 0;
			dsk_ext_ss <= 0;
		end
	end

	// Download addresses (SDRAM word addresses):
	//   ROM:      $500000 + offset
	//   Floppy 1: $600000 + offset
	//   Floppy 2: $700000 + offset
	reg [22:0] dio_a;
	reg [15:0] dio_data;
	reg        dio_write;

	always @(posedge clk_sys) begin
		reg old_cyc = 0;
		if(ioctl_write) begin
			dio_data <= {ioctl_data[7:0], ioctl_data[15:8]};
			case (dio_index[1:0])
				2'b01:   dio_a <= 23'h600000 + {3'b0, dio_addr[19:0]};  // Floppy 1
				2'b10:   dio_a <= 23'h700000 + {3'b0, dio_addr[19:0]};  // Floppy 2
				default: dio_a <= {5'b01010, dio_addr[17:0]};            // ROM at $500000
			endcase
			ioctl_wait <= 1;
		end

		old_cyc <= dioBusControl;
		if(~dioBusControl) dio_write <= ioctl_wait;
		if(old_cyc & ~dioBusControl & dio_write) ioctl_wait <= 0;
	end


	// sdram used for ram/rom maps directly into 68k address space
	wire download_cycle = dio_download && dioBusControl;
	////////////////////////// SDRAM /////////////////////////////////

	// SDRAM Address mapping for Mac LC (V8-style):
	// memoryAddr[22:0] is already the SDRAM word address from addrController
	// Download path uses dio_a[22:0] directly
	wire [24:0] sdram_addr = download_cycle ? {2'b00, dio_a[22:0]} :
	                                          {2'b00, memoryAddr[22:0]};
	wire [15:0] sdram_din  = download_cycle ? dio_data              : memoryDataOut;
	wire  [1:0] sdram_ds   = download_cycle ? 2'b11                 : { !_memoryUDS, !_memoryLDS };
	wire        sdram_we   = download_cycle ?
							 dio_write             : !_ramWE;
	wire        sdram_oe   = download_cycle ?
							 1'b0                  : (!_ramOE || !_romOE || dskReadAckInt || dskReadAckExt);
	wire [15:0] sdram_do   = download_cycle ? 16'hffff : (dskReadAckInt || dskReadAckExt) ? extra_rom_data_demux : sdram_out;
	// during rom/disk download ffff is returned so the screen is black during download
	// "extra rom" is used to hold the disk image. It's expected to be byte wide and
	// we thus need to properly demultiplex the word returned from sdram in that case
	wire [15:0] extra_rom_data_demux = memoryAddr[0]?
							 {sdram_out[7:0],sdram_out[7:0]}:{sdram_out[15:8],sdram_out[15:8]};
	wire [15:0] sdram_out;

	assign SDRAM_CKE = 1;

	sdram sdram
	(
		// system interface
		.init           ( !pll_locked              ),
		.clk_64         ( clk_mem                  ),
		.clk_8          ( clk8                     ),

		.sd_clk         ( SDRAM_CLK                ),
		.sd_data        ( SDRAM_DQ                 ),
		.sd_addr        ( SDRAM_A                  ),
		.sd_dqm         ( {SDRAM_DQMH, SDRAM_DQML} ),
		.sd_cs          ( SDRAM_nCS                ),
		.sd_ba          ( SDRAM_BA                 ),
		.sd_we          ( SDRAM_nWE                ),
		.sd_ras         ( SDRAM_nRAS               ),
		.sd_cas         ( SDRAM_nCAS               ),


		// cpu/chipset interface
		// map rom to sdram word address $200000 - $20ffff
		.din            ( sdram_din                ),
		.addr           ( sdram_addr               ),
		.ds             ( sdram_ds                 ),
		.we             ( sdram_we                 ),
		.oe             ( sdram_oe                 ),
		.dout           ( sdram_out                )
	);

endmodule