/*
 * CUDA Testbench
 * Tests basic CUDA protocol commands
 */

`timescale 1ns/1ps

module cuda_tb;

    reg         clk;
    reg         clk8_en;
    reg         reset;
    
    wire [7:0]  via_pb_i;
    wire [7:0]  cuda_pb_o;
    wire [7:0]  cuda_pb_oe;
    
    reg         via_sr_active;
    reg         via_sr_out;
    reg  [7:0]  via_sr_data_out;
    wire [7:0]  cuda_sr_data_in;
    wire        cuda_sr_trigger;
    
    wire        cuda_cb1;
    wire        cuda_cb1_oe;
    wire        cuda_cb2;
    wire        cuda_cb2_oe;
    
    reg         adb_data_in;
    wire        adb_data_out;
    wire        adb_data_oe;
    
    wire        iic_sda;
    wire        iic_scl;
    
    wire        reset_out;
    wire        nmi_out;
    wire        dfac_latch;
    
    // VIA Port B simulation
    reg  [7:0]  via_pb_out;
    reg  [7:0]  via_pb_oe_reg;
    
    assign via_pb_i = (via_pb_oe_reg & via_pb_out) | 
                      (cuda_pb_oe & cuda_pb_o) |
                      (~(via_pb_oe_reg | cuda_pb_oe) & 8'hFF); // Pull-ups
    
    // Instantiate CUDA
    cuda dut (
        .clk(clk),
        .clk8_en(clk8_en),
        .reset(reset),
        .via_pb_i(via_pb_i),
        .cuda_pb_o(cuda_pb_o),
        .cuda_pb_oe(cuda_pb_oe),
        .via_sr_active(via_sr_active),
        .via_sr_out(via_sr_out),
        .via_sr_data_out(via_sr_data_out),
        .cuda_sr_data_in(cuda_sr_data_in),
        .cuda_sr_trigger(cuda_sr_trigger),
        .cuda_cb1(cuda_cb1),
        .cuda_cb1_oe(cuda_cb1_oe),
        .cuda_cb2(cuda_cb2),
        .cuda_cb2_oe(cuda_cb2_oe),
        .adb_data_in(adb_data_in),
        .adb_data_out(adb_data_out),
        .adb_data_oe(adb_data_oe),
        .iic_sda(iic_sda),
        .iic_scl(iic_scl),
        .reset_out(reset_out),
        .nmi_out(nmi_out),
        .dfac_latch(dfac_latch)
    );
    
    // Clock generation - 50MHz system clock, 8MHz enable
    initial clk = 0;
    always #10 clk = ~clk;  // 50MHz
    
    reg [2:0] clk_div;
    always @(posedge clk) begin
        if (reset)
            clk_div <= 0;
        else
            clk_div <= clk_div + 1'd1;
    end
    assign clk8_en = (clk_div == 3'd0);  // Divide by 8 ≈ 6.25MHz
    
    // Test sequence
    initial begin
        $dumpfile("cuda_tb.vcd");
        $dumpvars(0, cuda_tb);
        
        // Initialize
        reset = 1;
        via_sr_active = 0;
        via_sr_out = 0;
        via_sr_data_out = 8'h00;
        via_pb_out = 8'h00;
        via_pb_oe_reg = 8'h00;
        adb_data_in = 1;
        
        #1000;
        reset = 0;
        #1000;
        
        $display("=== CUDA Testbench ===");
        $display("Time: %0t - Reset complete", $time);
        
        // Test 1: Check TREQ is asserted (ready)
        #5000;
        $display("Time: %0t - TREQ=%b (should be 0=ready)", $time, cuda_pb_o[1]);
        
        // Test 2: Read CUDA Version
        $display("\n=== Test 2: Read CUDA Version ===");
        send_cuda_command(8'h11, 8'h00, 0, 8'h00);
        #10000;
        
        // Test 3: Read PRAM location 0x08
        $display("\n=== Test 3: Read PRAM[0x08] ===");
        send_cuda_command(8'h07, 8'h01, 1, 8'h08);
        #10000;
        
        // Test 4: Write PRAM location 0x10
        $display("\n=== Test 4: Write PRAM[0x10] = 0x42 ===");
        send_cuda_command(8'h0C, 8'h02, 2, 8'h10);
        #10000;
        
        // Test 5: Read back PRAM location 0x10
        $display("\n=== Test 5: Read PRAM[0x10] (verify write) ===");
        send_cuda_command(8'h07, 8'h01, 1, 8'h10);
        #10000;
        
        $display("\n=== Testbench Complete ===");
        #5000;
        $finish;
    end
    
    // Task to send a CUDA command
    task send_cuda_command;
        input [7:0] cmd;
        input [7:0] len;
        input integer data_bytes;
        input [7:0] data0;
        begin
            $display("Sending command: 0x%02h, length: %0d", cmd, len);
            
            // Assert TIP to start transaction
            via_pb_out[3] = 1;  // TIP
            via_pb_oe_reg[3] = 1;
            #2000;
            
            // Send command byte
            send_byte(cmd);
            #2000;
            
            // Send length
            send_byte(len);
            #2000;
            
            // Send data bytes if any
            if (data_bytes > 0) begin
                send_byte(data0);
                #2000;
            end
            
            // Deassert TIP
            via_pb_out[3] = 0;
            via_pb_oe_reg[3] = 0;
            #2000;
            
            // Wait for response (TREQ should go low when CUDA has response)
            wait_for_treq_low();
            
            // Read response length
            // In real VIA, this would be shift register read
            #5000;
            
            $display("Command complete");
        end
    endtask
    
    // Task to send a byte via shift register
    task send_byte;
        input [7:0] data;
        begin
            via_sr_active = 1;
            via_sr_out = 1;  // VIA sending to CUDA
            via_sr_data_out = data;
            
            // Wait for shift to complete (CUDA will clock it)
            #5000;
            
            via_sr_active = 0;
            via_sr_out = 0;
        end
    endtask
    
    // Task to wait for TREQ to go low (CUDA ready with response)
    task wait_for_treq_low;
        integer timeout;
        begin
            timeout = 0;
            while (cuda_pb_o[1] != 0 && timeout < 10000) begin
                #100;
                timeout = timeout + 1;
            end
            
            if (timeout >= 10000) begin
                $display("WARNING: Timeout waiting for TREQ");
            end else begin
                $display("TREQ asserted (response ready)");
            end
        end
    endtask
    
    // Monitor CUDA outputs
    always @(posedge clk) begin
        if (clk8_en && cuda_sr_trigger) begin
            $display("Time: %0t - CUDA SR Trigger, data=0x%02h", 
                     $time, cuda_sr_data_in);
        end
    end

endmodule
