// Mac LC Pseudo-VIA
// Based on MAME's pseudovia.cpp by R. Belmont
//
// Mapped at $F26000-$F27FFF in CPU space (V8 internal 0x526000)
// Two access modes:
//   - Native mode (offset < 0x100): Direct register access
//   - VIA-compat mode (offset >= 0x100): Aliases native Group 0 registers
//
// Native mode decodes only addr[4] (group) and addr[1:0] (register):
//   Group 0 (addr[4]=0): Port B, RAM Config, Slot Status, IFR
//   Group 1 (addr[4]=1): Video Config, (unused), Slot IER, IER
//
// VIA-compat mode (offset >= 0x100) decodes addr[1:0] to access Group 0.

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
    input asc_irq,       // ASC interrupt
    output reg irq_out,

    // Config from top level
    input [7:0] ram_config,  // V8 RAM config byte (MAME encoding)
    input [3:0] monitor_id,  // Monitor ID for video config

    // Video config output (set by ROM, bits 2:0 = bpp mode)
    output reg [7:0] video_config,

    // RAM config output (active value, writable by ROM)
    output [7:0] ram_config_out
);

// RAM config output: expose current value for address controller
assign ram_config_out = ram_cfg;

// Native registers (8 total, 2 groups of 4)
// Group 0: port_b, ram_cfg, slot_status, ifr
// Group 1: video_cfg, (unused), slot_ier, ier
reg [7:0] port_b;
reg [7:0] ram_cfg;      // Writable RAM config register
reg [7:0] ifr;          // Interrupt flag register
reg [7:0] slot_ier;     // Slot interrupt enable register
reg [7:0] ier;          // Main interrupt enable register

// Slot interrupt status - active LOW
// Bit 6: VBlank (active low = VBlank is happening)
// Bit 5: Slot IRQ
// Bit 4: ASC IRQ
// Bits 3: Slot 0 IRQ
wire [7:0] slot_status = {1'b0, ~vblank_irq, ~slot_irq, ~asc_irq, 3'b111, 1'b1};

// IRQ recalculation
wire [7:0] slot_irqs = (~slot_status) & 8'h78;  // Check bits 3-6 (slots + vblank)
wire [7:0] slot_irqs_masked = slot_irqs & (slot_ier & 8'h78);
wire any_slot_irq = |slot_irqs_masked;

wire [7:0] active_ifr = ifr & ier & 8'h1B;
wire irq_pending = |active_ifr;

// Debug counter
integer pvia_reg10_reads = 0;

// Register decode: {addr[4], addr[1:0]} for native mode
wire [2:0] reg_sel = {addr[4], addr[1:0]};

// VIA-compat mode uses addr[1:0] to alias Group 0
wire is_native = (addr[12:8] == 5'b00000);
wire [1:0] compat_reg = addr[1:0];

always @(posedge clk_sys) begin
    if (reset) begin
        port_b <= 8'h00;
        ram_cfg <= ram_config;  // Init from hardware config (MAME: ram_size(0xC0))
        ifr <= 8'h00;
        slot_ier <= 8'h00;
        ier <= 8'h00;
        irq_out <= 1'b0;
        video_config <= 8'h02;  // Default to 4bpp mode
    end else begin
        // Update slot IRQ summary in IFR (bit 1 = any slot)
        if (any_slot_irq)
            ifr[1] <= 1'b1;
        else
            ifr[1] <= 1'b0;

        // Update IRQ output
        if (irq_pending) begin
            ifr[7] <= 1'b1;
            irq_out <= 1'b1;
        end else begin
            ifr[7] <= 1'b0;
            irq_out <= 1'b0;
        end

        if (req) begin
            if (is_native) begin
                // Native mode: decode {addr[4], addr[1:0]}
                if (we) begin
                    case (reg_sel)
                        3'b000: begin  // $00: Port B
                            port_b <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Port B = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b001: begin  // $01: RAM Config (writable per MAME)
                            ram_cfg <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE RAM Config = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b010: begin  // $02: Slot Status
                            // Write 1 to bit 6 to clear VBlank flag
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Slot Status = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b011: begin  // $03: IFR
                            if (data_in[7])
                                ifr <= ifr | (data_in & 8'h7F);
                            else
                                ifr <= ifr & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE IFR = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b100: begin  // $10: Video Config
                            video_config <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Video Config = %02x (bpp mode = %d) @%0t",
                                     data_in, data_in[2:0], $time);
                            `endif
                        end

                        3'b101: ;  // $11: unused

                        3'b110: begin  // $12: Slot IER
                            if (data_in[7])
                                slot_ier <= slot_ier | (data_in & 8'h7F);
                            else
                                slot_ier <= slot_ier & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Slot IER = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b111: begin  // $13: IER
                            if (data_in[7]) begin
                                ier <= ier | (data_in & 8'h7F);
                                if (data_in == 8'hFF)
                                    ier <= 8'h1F;
                            end else begin
                                ier <= ier & ~(data_in & 8'h7F);
                            end
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE IER = %02x @%0t", data_in, $time);
                            `endif
                        end
                    endcase
                end else begin
                    // Read native mode
                    case (reg_sel)
                        3'b000: begin  // $00: Port B
                            data_out <= port_b;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Port B -> %02x @%0t", port_b, $time);
                            `endif
                        end

                        3'b001: begin  // $01: RAM Config (OR bit 2 on read)
                            data_out <= ram_cfg | 8'h04;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ RAM Config -> %02x @%0t", ram_cfg | 8'h04, $time);
                            `endif
                        end

                        3'b010: begin  // $02: Slot Status
                            data_out <= slot_status;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Slot Status -> %02x @%0t", slot_status, $time);
                            `endif
                        end

                        3'b011: begin  // $03: IFR
                            data_out <= ifr;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ IFR -> %02x @%0t", ifr, $time);
                            `endif
                        end

                        3'b100: begin  // $10: Video Config
                            data_out <= (video_config & 8'hC7) | ((monitor_id[2:0]) << 3);
                            pvia_reg10_reads <= pvia_reg10_reads + 1;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Video Config -> %02x @%0t",
                                     (video_config & 8'hC7) | ((monitor_id[2:0]) << 3), $time);
                            `endif
                        end

                        3'b101: begin  // $11: unused
                            data_out <= 8'h00;
                        end

                        3'b110: begin  // $12: Slot IER
                            data_out <= slot_ier & 8'h7F;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Slot IER -> %02x @%0t", slot_ier & 8'h7F, $time);
                            `endif
                        end

                        3'b111: begin  // $13: IER
                            data_out <= ier & 8'h7F;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ IER -> %02x @%0t", ier & 8'h7F, $time);
                            `endif
                        end
                    endcase
                end
            end else begin
                // VIA-compat mode: offset >= 0x100
                // Aliases Group 0 native registers via addr[1:0]
                if (we) begin
                    case (compat_reg)
                        2'b00: begin  // Port B
                            port_b <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: WRITE Port B = %02x @%0t", data_in, $time);
                            `endif
                        end
                        2'b01: begin  // RAM Config
                            ram_cfg <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: WRITE RAM Config = %02x @%0t", data_in, $time);
                            `endif
                        end
                        2'b10: begin  // Slot Status
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: WRITE Slot Status = %02x @%0t", data_in, $time);
                            `endif
                        end
                        2'b11: begin  // IFR
                            if (data_in[7])
                                ifr <= ifr | (data_in & 8'h7F);
                            else
                                ifr <= ifr & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: WRITE IFR = %02x @%0t", data_in, $time);
                            `endif
                        end
                    endcase
                end else begin
                    case (compat_reg)
                        2'b00: begin
                            data_out <= port_b;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: READ Port B -> %02x @%0t", port_b, $time);
                            `endif
                        end
                        2'b01: begin
                            data_out <= ram_cfg | 8'h04;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: READ RAM Config -> %02x @%0t", ram_cfg | 8'h04, $time);
                            `endif
                        end
                        2'b10: begin
                            data_out <= slot_status;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: READ Slot Status -> %02x @%0t", slot_status, $time);
                            `endif
                        end
                        2'b11: begin
                            data_out <= ifr;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: READ IFR -> %02x @%0t", ifr, $time);
                            `endif
                        end
                    endcase
                end
            end
        end
    end
end

endmodule
