// Mac LC Pseudo-VIA
// Based on MAME's pseudovia.cpp by R. Belmont
//
// Mapped at $F26000-$F27FFF in CPU space (V8 internal 0x526000)
// Two access modes:
//   - Native mode (offset < 0x100): Direct register access
//   - VIA-compat mode (offset >= 0x100): offset >> 9 gives register 0-15
//
// Native mode registers:
//   0x00: Port B output
//   0x01: RAM Config (read-only, from v8 config callbacks)
//   0x02: Slot/VBlank interrupt status (active low)
//   0x03: IFR (interrupt flag register)
//   0x10: Video config (monitor ID in bits 5:3)
//   0x12: Slot IER (interrupt enable)
//   0x13: IER (legacy VIA style)
//
// VIA-compat mode (offset >> 9):
//   1: Port A
//   13: IFR
//   14: IER

module pseudovia(
    input clk_sys,
    input reset,

    // CPU interface - full offset within $F26000-$F27FFF range
    input [12:0] addr,  // Offset 0x0000-0x1FFF
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,

    // Interrupts
    input vblank_irq,    // Active high VBlank signal
    input slot_irq,      // Slot interrupt
    output reg irq_out,

    // Config from top level
    input [1:0] ram_config,  // 0=128K, 1=512K, 2=1MB, 3=4MB
    input [3:0] monitor_id,  // Monitor ID for video config

    // Video config output (set by ROM, bits 2:0 = bpp mode)
    output reg [7:0] video_config
);

// Internal registers (256 bytes for native mode)
reg [7:0] regs [0:255];

// VIA-style IER and IFR (for VIA-compat mode access)
reg [7:0] ier;
reg [7:0] ifr;

// Port B data
reg [7:0] port_b;

// Slot interrupt status - active LOW
// Bit 6: VBlank (active low = VBlank is happening)
// Bits 3-5: Slot IRQs
wire [7:0] slot_status = {1'b0, ~vblank_irq, ~slot_irq, 4'b1111, 1'b1};

// IRQ recalculation
wire [7:0] slot_irqs = (~regs[2]) & 8'h78;  // Check bits 3-6 (slots + vblank)
wire [7:0] slot_irqs_masked = slot_irqs & (regs[8'h12] & 8'h78);
wire any_slot_irq = |slot_irqs_masked;

wire [7:0] active_ifr = regs[3] & ier & 8'h1B;
wire irq_pending = |active_ifr;

// Debug counter
integer pvia_access_count = 0;
integer pvia_reg10_reads = 0;

always @(posedge clk_sys) begin
    if (reset) begin
        ier <= 8'h00;
        ifr <= 8'h00;
        port_b <= 8'h00;
        irq_out <= 1'b0;
        video_config <= 8'h02;  // Default to 4bpp mode
        // Initialize regs
        regs[2] <= 8'h7F;  // All slot IRQs inactive (high = no IRQ)
        regs[3] <= 8'h00;
        regs[8'h12] <= 8'h00;
        regs[8'h13] <= 8'h00;
    end else begin
        // Update slot/vblank status (active low)
        regs[2] <= slot_status;

        // Update slot IRQ summary in IFR (bit 1 = any slot)
        if (any_slot_irq)
            regs[3][1] <= 1'b1;
        else
            regs[3][1] <= 1'b0;

        // Update IRQ output
        if (irq_pending) begin
            regs[3][7] <= 1'b1;
            ifr <= active_ifr | 8'h80;
            irq_out <= 1'b1;
        end else begin
            regs[3][7] <= 1'b0;
            ifr <= 8'h00;
            irq_out <= 1'b0;
        end

        if (req) begin
            // Debug: log first 20 accesses
            if (pvia_access_count < 20) begin
                $display("PVIA %s: addr=%04x native=%d", we ? "WR" : "RD", addr, addr[12:8] == 5'b00000);
                pvia_access_count <= pvia_access_count + 1;
            end
            if (addr[12:8] == 5'b00000) begin
                // Native mode: offset 0x00-0xFF
                if (we) begin
                    case (addr[7:0])
                        8'h00: port_b <= data_in;  // Port B output

                        8'h01: ;  // Config - read only

                        8'h02: begin
                            // Write 1 to bit 6 to clear VBlank flag
                            regs[2] <= regs[2] | (data_in & 8'h40);
                        end

                        8'h03: begin
                            // IFR write - bit 7 controls set/clear
                            if (data_in[7])
                                regs[3] <= regs[3] | (data_in & 8'h7F);
                            else
                                regs[3] <= regs[3] & ~(data_in & 8'h7F);
                        end

                        8'h10: begin
                            regs[8'h10] <= data_in;
                            video_config <= data_in;
                            $display("PVIA: Video config WRITE = %02x (bpp mode = %d)",
                                     data_in, data_in[2:0]);
                        end

                        8'h12: begin
                            // Slot IER - bit 7 controls set/clear
                            if (data_in[7])
                                regs[8'h12] <= regs[8'h12] | (data_in & 8'h7F);
                            else
                                regs[8'h12] <= regs[8'h12] & ~(data_in & 8'h7F);
                        end

                        8'h13: begin
                            // IER - bit 7 controls set/clear
                            if (data_in[7]) begin
                                regs[8'h13] <= regs[8'h13] | (data_in & 8'h7F);
                                // Special case from MAME
                                if (data_in == 8'hFF)
                                    regs[8'h13] <= 8'h1F;
                            end else begin
                                regs[8'h13] <= regs[8'h13] & ~(data_in & 8'h7F);
                            end
                        end

                        default: regs[addr[7:0]] <= data_in;
                    endcase
                end else begin
                    // Read native mode
                    case (addr[7:0])
                        8'h00: data_out <= port_b;  // Port B

                        8'h01: begin
                            // RAM config register (from v8 callbacks)
                            // Return RAM size | 0x04 (bit 2 always set)
                            case (ram_config)
                                2'b00: data_out <= 8'h04;  // 128K
                                2'b01: data_out <= 8'h05;  // 512K
                                2'b10: data_out <= 8'h06;  // 1MB
                                2'b11: data_out <= 8'h07;  // 4MB
                            endcase
                        end

                        8'h02: data_out <= regs[2];  // Slot/VBlank status
                        8'h03: data_out <= regs[3];  // IFR

                        8'h10: begin
                            // Video config - monitor ID in bits 6:3 (matches MAME: montype << 3)
                            data_out <= {1'b0, monitor_id, 3'b000};
                            pvia_reg10_reads <= pvia_reg10_reads + 1;
                            $display("PVIA: Video config READ[%0d], monitor_id=%d, returning %02x",
                                     pvia_reg10_reads, monitor_id, {1'b0, monitor_id, 3'b000});
                        end

                        8'h12: data_out <= regs[8'h12] & 8'h7F;  // Slot IER, bit 7 always 0
                        8'h13: data_out <= regs[8'h13] & 8'h7F;  // IER, bit 7 always 0

                        default: data_out <= regs[addr[7:0]];
                    endcase
                end
            end else begin
                // VIA-compat mode: offset >= 0x100
                // Register = offset >> 9 (bits 12:9)
                case (addr[12:9])
                    4'd1: begin  // Port A
                        if (we)
                            ; // Port A output - could connect to handler
                        else
                            data_out <= 8'hD5;  // Default Port A read value (from MAME)
                    end

                    4'd13: begin  // IFR
                        if (we) begin
                            if (data_in[7])
                                ifr <= 8'h7F;  // Writing 0x80+ clears all
                        end else begin
                            data_out <= ifr;
                        end
                    end

                    4'd14: begin  // IER
                        if (we) begin
                            if (data_in[7])
                                ier <= ier | (data_in & 8'h7F);
                            else
                                ier <= ier & ~(data_in & 8'h7F);
                        end else begin
                            data_out <= ier;
                        end
                    end

                    default: data_out <= 8'h00;
                endcase
            end
        end
    end
end

endmodule
