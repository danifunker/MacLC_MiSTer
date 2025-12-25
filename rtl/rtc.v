/* PRAM - RTC implementation for plus_too */

module rtc (
	input         clk,
	input         reset,

	input  [32:0] timestamp, // unix timestamp
	input         _cs,
	input         ck,
	input         dat_i,
	output reg    dat_o
);

reg   [2:0] bit_cnt;
reg         ck_d;
reg   [7:0] din;
reg   [7:0] cmd;
reg   [7:0] dout;
reg         cmd_mode;
reg         receiving;
reg  [31:0] secs;
reg  [31:0] secs2;
reg   [7:0] ram[20];
reg  [24:0] clocktoseconds;
reg   [7:0] cs_deassert_cnt;  // Counter for CS debouncing

initial begin
	dat_o = 1'b1;  // RTC data line idles high
	ck_d = 1'b1;
	dout = 8'hFF;
	ram[5'h00] = 8'hA8;
	ram[5'h01] = 8'h00;
	ram[5'h02] = 8'h00;
	ram[5'h03] = 8'h22;
	ram[5'h04] = 8'hCC;
	ram[5'h05] = 8'h0A;
	ram[5'h06] = 8'hCC;
	ram[5'h07] = 8'h0A;
	ram[5'h08] = 8'h00;
	ram[5'h09] = 8'h00;
	ram[5'h0A] = 8'h00;
	ram[5'h0B] = 8'h00;
	ram[5'h0C] = 8'h00;
	ram[5'h0D] = 8'h02;
	ram[5'h0E] = 8'h63;
	ram[5'h0F] = 8'h00;
	ram[5'h10] = 8'h03;
	ram[5'h11] = 8'h88;
	ram[5'h12] = 8'h00;
	ram[5'h13] = 8'h6C;
end

initial secs = 0;

always @(posedge clk) begin
	if (reset) begin
		bit_cnt <= 0;
		receiving <= 1;
		cmd_mode <= 1;
		dat_o <= 1;
		cs_deassert_cnt <= 0;
	//	sec_cnt <= 0;
	end 
	else begin

		// timestamp is only sent at core load
		if (secs==0)
				secs <= timestamp[31:0] + 2082844800; // difference between unix epoch and mac epoch

		// we need to add one to the seconds
		clocktoseconds<= clocktoseconds + 1'd1;
		if (32499999==clocktoseconds) // every 32mhz we increment secs by one
		begin
			clocktoseconds<=0;
			secs<=secs+1;
		end

		// Mac LC ROM uses DDRB toggles for RTC clocking, which briefly deasserts CS
		// Track clock edges regardless of CS state (CS and clock change simultaneously)
		ck_d <= ck;

		if (_cs) begin
			cs_deassert_cnt <= cs_deassert_cnt + 1'd1;
			if (cs_deassert_cnt >= 8'd100) begin  // Only reset after sustained deselect
				bit_cnt <= 0;
				receiving <= 1;
				cmd_mode <= 1;
			end
			// Keep dat_o as-is when deselected (don't force to 1)
		end
		else begin
			cs_deassert_cnt <= 8'd0;  // Reset counter when selected
		end

		// Process clock edges even if CS just changed (both happen on same DDRB write)
		// Only process when we were recently selected (cs_deassert_cnt low)
		if (cs_deassert_cnt < 8'd10) begin
			// transmit at the falling edge
			if (ck_d & ~ck & !receiving)
				dat_o <= dout[7-bit_cnt];
			// receive at the rising edge
			if (~ck_d & ck) begin
				bit_cnt <= bit_cnt + 1'd1;
				if (receiving)
					din <= {din[6:0], dat_i};

				if (bit_cnt == 7) begin
					if (receiving && cmd_mode) begin
						// command byte received
						cmd_mode <= 0;
						receiving <= ~din[6];
						cmd <= {din[6:0], dat_i};
						casez ({din[5:0], dat_i})
							7'b00?0001: dout <= secs[7:0];
							7'b00?0101: dout <= secs[15:8];
							7'b00?1001: dout <= secs[23:16];
							7'b00?1101: dout <= secs[31:24];
							7'b010??01: dout <= ram[{3'b100, din[2:1]}];
							7'b1????01: dout <= ram[din[4:1]];
							default: ;
						endcase
					end
					if (receiving && !cmd_mode) begin
						// data byte received
						casez (cmd[6:0])
							7'b0000001: secs[7:0] <= {din[6:0], dat_i};
							7'b0000101: secs[15:8] <= {din[6:0], dat_i};
							7'b0001001: secs[23:16] <= {din[6:0], dat_i};
							7'b0001101: secs[31:24] <= {din[6:0], dat_i};
							7'b010??01: ram[{3'b100, cmd[3:2]}] <= {din[6:0], dat_i};
							7'b1????01: ram[cmd[5:2]] <= {din[6:0], dat_i};
							default: ;
						endcase
					end
				end
			end
		end
	end
end

endmodule
