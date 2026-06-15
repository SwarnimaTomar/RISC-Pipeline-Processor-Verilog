// TESTBENCH: 5-Stage Pipelined RISC Processor

// Test Program covers:
//   1. Basic ADDI (load immediate values)
//   2. ADD with data forwarding (back-to-back dependent instructions)
//   3. SUB with data forwarding
//   4. STORE to memory
//   5. LOAD from memory (creates load-use hazard)
//   6. ADD after LOAD (load-use hazard -> pipeline must stall 1 cycle)
//   7. BEQ not-taken (Rs1 != Rs2)
//   8. BEQ taken (Rs1 = Rs2 -> pipeline must flush)
//
// Expected Register Results After Program:
//   R1 = 5    R2 = 3    R3 = 8 (5+3)    R4 = 7 (branch target executed)
//   R5 = 0 (8&2)  R6 = 8 (loaded from mem[0])  R7 = 13 (8+5)

`timescale 1ns/1ps

module tb_risc_pipeline;

    // DUT Signals
    reg clk, rst;

    // Instantiate DUT
    risc_pipeline_top DUT(
        .clk(clk),
        .rst(rst)
    );

    // Clock: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    integer i;

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_risc_pipeline);
        
        rst = 1;

        // Instructions are hardcoded in instruction_memory ROM (case statement)
        // No need to load them here - see MODULE 2 in RISC_Pipeline_Processor.v
        // Program summary:
        //   Addr 0-1:  ADDI R1=5, R2=3
        //   Addr 2-4:  ADD/SUB/AND with forwarding
        //   Addr 5-7:  STORE/LOAD/ADD with load-use stall
        //   Addr 8-10: BEQ not-taken test
        //   Addr 11-15: BEQ taken test (branch to addr 15, flush addr 14)

        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;

        // Run for 40 cycles
        repeat(40) @(posedge clk);

        // Print results
        $display("---- register file after execution ----");
        
        for(i = 0; i < 8; i = i + 1)
            $display("R%0d = %0d", i, DUT.RF.registers[i]);

        $display("");
        $display("---- checking results ----");

        if(DUT.RF.registers[3] == 8)
            $display("PASS: R3 = 8 (ADD forwarding worked)");
        else
            $display("FAIL: R3 = %0d, expected 8", DUT.RF.registers[3]);

        if(DUT.RF.registers[4] == 7)
            $display("PASS: R4 = 7 (branch target executed)");
        else
            $display("FAIL: R4 = %0d, expected 7", DUT.RF.registers[4]);

        if(DUT.RF.registers[5] == 0)
            $display("PASS: R5 = 0 (AND result correct)");
        else
            $display("FAIL: R5 = %0d, expected 0", DUT.RF.registers[5]);

        if(DUT.RF.registers[6] == 8)
            $display("PASS: R6 = 8 (LOAD worked)");
        else
            $display("FAIL: R6 = %0d, expected 8", DUT.RF.registers[6]);

        if(DUT.RF.registers[7] == 13)
            $display("PASS: R7 = 13 (load-use stall handled)");
        else
            $display("FAIL: R7 = %0d, expected 13 (load-use stall issue?)", DUT.RF.registers[7]);

        if(DUT.RF.registers[3] != 63)
            $display("PASS: R3 not 63, branch flush worked");
        else
            $display("FAIL: R3 = 63, flushed instruction executed wrongly");

        // STORE verification: R6 was loaded from mem[0] after STORE
        // If R6 = 8, STORE wrote correctly and LOAD read it back correctly
        if(DUT.RF.registers[6] == 8)
            $display("PASS: mem[0] = 8 verified via R6 (STORE + LOAD worked)");
        else
            $display("FAIL: R6 = %0d, expected 8 (STORE or LOAD failed)", DUT.RF.registers[6]);

        $finish;
    end

    // Monitor during sim
    always @(posedge clk) begin
        $display("t=%0t pc=%0d stall=%b branch_taken=%b fwd_a=%b fwd_b=%b",
            $time,
            DUT.pc_current,
            DUT.stall,
            DUT.branch_taken,
            DUT.forward_a,
            DUT.forward_b);
    end

endmodule
