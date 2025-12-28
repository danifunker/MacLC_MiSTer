/*
 * Mac LC VIA/Egret Boot Sequence Testbench
 * 
 * This testbench reproduces the exact boot sequence captured from MAME logs.
 * It generates the Egret signals (VIA_CLOCK, VIA_DATA, XCVR_SESSION) and 
 * monitors the VIA's IFR register to verify correct behavior.
 *
 * Based on MAME Mac LC boot logs captured December 2024
 */

`timescale 1ns / 1ps

module maclc_via_egret_boot_tb;

    // Clock and reset
    reg clk_16mhz;          // 68020 clock
    reg clk_2mhz;           // Egret clock (~2.097 MHz from 32.768kHz * 128)
    reg reset_n;
    
    // Egret outputs (inputs to VIA)
    reg egret_via_clock;    // Connected to VIA CA1
    reg egret_via_data;     // Connected to VIA CB2
    reg egret_xcvr_session; // Connected to VIA (transaction framing)
    reg egret_reset_n;      // 68020 reset control
    
    // VIA interface signals
    wire [15:0] via_addr;   // A1-A4 for register select
    wire [7:0] via_data_out;
    reg [7:0] via_data_in;
    reg via_cs_n;
    reg via_rw;             // 1=read, 0=write
    
    // VIA interrupt outputs
    wire via_irq_n;
    
    // Internal signals
    reg [7:0] via_ifr;      // Monitor IFR register
    integer cycle_count;
    integer test_step;
    
    // DUT - Your VIA module (adjust port names as needed)
    // Replace this with your actual VIA module instantiation
    /*
    via_6522 dut (
        .clk(clk_16mhz),
        .reset_n(reset_n),
        .addr(via_addr[3:0]),
        .data_in(via_data_in),
        .data_out(via_data_out),
        .cs_n(via_cs_n),
        .rw(via_rw),
        .ca1(egret_via_clock),
        .ca2(),
        .cb1(),
        .cb2(egret_via_data),
        .irq_n(via_irq_n)
    );
    */
    
    // Clock generation
    initial begin
        clk_16mhz = 0;
        forever #31.25 clk_16mhz = ~clk_16mhz;  // 16 MHz
    end
    
    initial begin
        clk_2mhz = 0;
        forever #238.4 clk_2mhz = ~clk_2mhz;    // ~2.097 MHz (32768*128/2)
    end
    
    // VCD dump for waveform viewing
    initial begin
        $dumpfile("maclc_boot_sequence.vcd");
        $dumpvars(0, maclc_via_egret_boot_tb);
    end
    
    // Test sequence - reproduces MAME boot log
    initial begin
        // Initialize
        reset_n = 0;
        egret_reset_n = 0;
        egret_via_clock = 0;
        egret_via_data = 0;
        egret_xcvr_session = 0;
        via_cs_n = 1;
        via_rw = 1;
        via_data_in = 8'h00;
        cycle_count = 0;
        test_step = 0;
        
        $display("=================================================");
        $display("Mac LC VIA/Egret Boot Sequence Test");
        $display("=================================================");
        
        // Release reset
        #1000;
        reset_n = 1;
        #1000;
        
        $display("\n[STEP 0] Power-On: VIA_CLOCK=0, VIA_DATA=0, XCVR_SESSION=0");
        $display("Time: %0t ns", $time);
        
        // Wait for initial settling
        #5000;
        
        // ===================================================================
        // STEP 1: Assert XCVR_SESSION (PC=0x1246 in MAME logs)
        // ===================================================================
        test_step = 1;
        $display("\n[STEP 1] Assert XCVR_SESSION and set VIA_CLOCK=1");
        $display("Time: %0t ns", $time);
        
        @(posedge clk_2mhz);
        egret_xcvr_session = 1;
        egret_via_clock = 1;
        #500;
        
        // Check VIA CA1 response
        check_via_ifr("After XCVR_SESSION assert", 8'h02); // Expect CA1 flag
        
        // ===================================================================
        // STEP 2: Release 68020 from reset
        // ===================================================================
        test_step = 2;
        $display("\n[STEP 2] Release 68020 from reset");
        $display("Time: %0t ns", $time);
        
        @(posedge clk_2mhz);
        egret_reset_n = 1;
        #1000;
        
        // ===================================================================
        // STEP 3: Send clock pulses (data=0) - Pattern from PC=0x14ef-0x152b
        // ===================================================================
        test_step = 3;
        $display("\n[STEP 3] Send 8 clock pulses with VIA_DATA=0");
        $display("Time: %0t ns", $time);
        
        repeat (8) begin
            send_bit(1'b0);
            #100;
        end
        
        // Check IFR after byte transmission
        check_via_ifr("After 8 clock pulses", 8'h16); // CA1 + CB1 + enabled
        
        // ===================================================================
        // STEP 4: De-assert XCVR_SESSION (PC=0x154b)
        // ===================================================================
        test_step = 4;
        $display("\n[STEP 4] De-assert XCVR_SESSION (end of transaction)");
        $display("Time: %0t ns", $time);
        
        @(posedge clk_2mhz);
        egret_xcvr_session = 0;
        #500;
        
        // ===================================================================
        // STEP 5: Send another 8 clock pulses - Pattern from PC=0x1552-0x1570
        // ===================================================================
        test_step = 5;
        $display("\n[STEP 5] Send 8 more clock pulses with VIA_DATA=0");
        $display("Time: %0t ns", $time);
        
        repeat (8) begin
            send_bit(1'b0);
            #100;
        end
        
        // ===================================================================
        // STEP 6: First data byte with start bit - Pattern from PC=0x15cc-0x1639
        // ===================================================================
        test_step = 6;
        $display("\n[STEP 6] Send first data byte (start bit + data)");
        $display("Time: %0t ns", $time);
        
        // Start bit (DATA=1)
        send_bit(1'b1);
        #100;
        
        check_via_ifr("After start bit", 8'h1A); // CA1 + CB2 + enabled
        
        // Send 7 more bits (all 0 for this example)
        repeat (7) begin
            send_bit(1'b0);
            #100;
        end
        
        // Stop bit (DATA=1)
        send_bit(1'b1);
        #100;
        
        // ===================================================================
        // STEP 7: Re-assert XCVR_SESSION - Pattern from PC=0x164f
        // ===================================================================
        test_step = 7;
        $display("\n[STEP 7] Re-assert XCVR_SESSION for next transaction");
        $display("Time: %0t ns", $time);
        
        @(posedge clk_2mhz);
        egret_xcvr_session = 1;
        #500;
        
        // ===================================================================
        // STEP 8: Simulate 68020 reading VIA IFR
        // ===================================================================
        test_step = 8;
        $display("\n[STEP 8] Simulate 68020 reading VIA IFR register");
        $display("Time: %0t ns", $time);
        
        // Read IFR (address 0x0D in VIA, offset 0xD from base)
        cpu_read_via(4'hD);
        #500;
        
        // Read again to clear interrupt
        cpu_read_via(4'hD);
        #500;
        
        check_via_ifr("After IFR read/clear", 8'h00); // Should be cleared
        
        // ===================================================================
        // STEP 9: Continue boot sequence with more bytes
        // ===================================================================
        test_step = 9;
        $display("\n[STEP 9] Send additional bytes (boot continues...)");
        $display("Time: %0t ns", $time);
        
        // Send a few more clock pulses to show continuation
        repeat (16) begin
            send_bit($random & 1);
            #100;
        end
        
        // ===================================================================
        // End of test
        // ===================================================================
        #10000;
        
        $display("\n=================================================");
        $display("Boot Sequence Test Complete");
        $display("=================================================");
        $display("Total cycles: %0d", cycle_count);
        $display("Test steps completed: %0d", test_step);
        
        $finish;
    end
    
    // Task: Send a single bit via VIA shift register protocol
    task send_bit(input bit_value);
        begin
            // Set data
            @(posedge clk_2mhz);
            egret_via_data = bit_value;
            egret_via_clock = 1;
            #476; // Half Egret clock period
            
            // Clock falling edge (this is when VIA CA1 should trigger)
            @(posedge clk_2mhz);
            egret_via_clock = 0;
            #476;
            
            cycle_count = cycle_count + 1;
            
            $display("  Bit %0d: DATA=%b CLOCK=1->0 (cycle %0d)", 
                     cycle_count, bit_value, cycle_count);
        end
    endtask
    
    // Task: Simulate 68020 reading from VIA
    task cpu_read_via(input [3:0] reg_addr);
        begin
            @(posedge clk_16mhz);
            via_cs_n = 0;
            via_rw = 1;  // Read
            // In real Mac LC, VIA at 0x50F00000, but we just need reg select
            #62.5;  // One 16MHz clock
            
            $display("  68020 Read VIA register 0x%0h: Data=0x%02h", 
                     reg_addr, via_data_out);
            
            @(posedge clk_16mhz);
            via_cs_n = 1;
            #62.5;
        end
    endtask
    
    // Task: Check VIA IFR register value
    task check_via_ifr(input [255:0] description, input [7:0] expected);
        begin
            // In real implementation, you would read this from your VIA module
            // For now, we'll simulate expected behavior
            #100;
            
            $display("  Check IFR - %0s", description);
            $display("    Expected: 0x%02h", expected);
            
            // TODO: Replace this with actual IFR read from your VIA module
            // via_ifr = dut.ifr_reg;  // Example
            // if (via_ifr == expected) begin
            //     $display("    PASS: IFR = 0x%02h", via_ifr);
            // end else begin
            //     $display("    FAIL: IFR = 0x%02h (expected 0x%02h)", via_ifr, expected);
            // end
        end
    endtask
    
    // Monitor VIA signals
    always @(posedge clk_16mhz) begin
        if (!via_irq_n) begin
            $display("[IRQ] VIA interrupt asserted at time %0t ns", $time);
        end
    end
    
    // Monitor Egret signal changes
    always @(egret_via_clock or egret_via_data or egret_xcvr_session) begin
        $display("[%0t] Egret signals: CLK=%b DATA=%b XCVR=%b", 
                 $time, egret_via_clock, egret_via_data, egret_xcvr_session);
    end

endmodule
