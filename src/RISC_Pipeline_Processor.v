// 16-bit 5-Stage Pipelined RISC Processor
// Stages: IF -> ID -> EX -> MEM -> WB
// Features: Data Forwarding, Hazard Detection, Branch Handling

// INSTRUCTION FORMAT (16-bit)
// R-type: [15:12]=opcode [11:9]=rd  [8:6]=rs1 [5:3]=rs2 [2:0]=funct
// I-type: [15:12]=opcode [11:9]=rd  [8:6]=rs1 [5:0]=imm6
// STORE:  [15:12]=opcode [11:9]=N/A [8:6]=rs1 [5:3]=rs2  (R-type, no imm)

//OPCODES:
// ADD=0000 ; rd, rs1, rs2   (R-type)
// SUB=0001 ; rd, rs1, rs2   (R-type)
// AND=0010 ; rd, rs1, rs2   (R-type)
// OR=0011  ; rd, rs1, rs2   (R-type)
// XOR=0100 ; rd, rs1, rs2   (R-type)
// ADDI=0101 ; rd, rs1, imm6  (I-type)
// LOAD=0110 ; rd, rs1, imm6  (I-type)  rd = mem[rs1+imm6]
// STORE=0111 ; rs1, rs2     (R-type)  mem[rs1] = rs2
// BEQ=1000  ; rs1, rs2, imm6(I-type)  branch if rs1==rs2
// NOP=1001  ; No Operation 

// REGISTER FILE: R0-R7 (R0 hardwired to 0)


// MODULE 1: PROGRAM COUNTER

module program_counter (
    input        clk,
    input        rst,
    input        stall,       // Hold PC on load-use hazard
    input [15:0] pc_next,     // Next PC (PC+1 or branch target)
    output reg [15:0] pc      // Current PC
);
    always @(posedge clk or posedge rst) begin
        if (rst)
            pc <= 16'd0;
        else if (!stall)
            pc <= pc_next;
        // If stall=1, PC holds its value (pipeline frozen)
    end
endmodule



// MODULE 2: INSTRUCTION MEMORY (synthesizable ROM, word-addressed)
// Instructions hardcoded as case statement - Vivado infers as ROM
// Program: tests forwarding, load-use stall, BEQ not-taken, BEQ taken

module instruction_memory (
    input  [15:0] pc,
    output reg [15:0] instr
);
    always @(*) begin
        case (pc[7:0])
            // Addr 0: ADDI R1, R0, 5  -> R1 = 5
            8'd0:  instr = {4'b0101, 3'b001, 3'b000, 6'b000101};
            // Addr 1: ADDI R2, R0, 3  -> R2 = 3
            8'd1:  instr = {4'b0101, 3'b010, 3'b000, 6'b000011};
            // Addr 2: ADD R3, R1, R2  -> R3 = 8 (forwarding: R1 from MEM, R2 from WB)
            8'd2:  instr = {4'b0000, 3'b011, 3'b001, 3'b010, 3'b000};
            // Addr 3: SUB R4, R1, R2  -> R4 = 2 (forwarding)
            8'd3:  instr = {4'b0001, 3'b100, 3'b001, 3'b010, 3'b000};
            // Addr 4: AND R5, R3, R4  -> R5 = 8 & 2 = 0
            8'd4:  instr = {4'b0010, 3'b101, 3'b011, 3'b100, 3'b000};
            // Addr 5: STORE R0(base), R3(data) -> mem[0] = 8
            8'd5:  instr = {4'b0111, 3'b000, 3'b000, 3'b011, 3'b000};
            // Addr 6: LOAD R6, R0, 0  -> R6 = mem[0] = 8
            8'd6:  instr = {4'b0110, 3'b110, 3'b000, 6'b000000};
            // Addr 7: ADD R7, R6, R1  -> R7 = 13 (LOAD-USE HAZARD -> stall 1 cycle)
            8'd7:  instr = {4'b0000, 3'b111, 3'b110, 3'b001, 3'b000};
            // Addr 8: BEQ R1, R2, +3  -> R1=5, R2=3, NOT equal -> no branch
            8'd8:  instr = {4'b1000, 3'b001, 3'b010, 6'b000011};
            // Addr 9: ADD R1, R1, R2  -> R1 = 8 (executes, branch not taken)
            8'd9:  instr = {4'b0000, 3'b001, 3'b001, 3'b010, 3'b000};
            // Addr 10: NOP
            8'd10: instr = 16'b1001_000_000_000_000;
            // Addr 11: ADDI R1, R0, 5 -> R1 = 5 (reset for BEQ taken test)
            8'd11: instr = {4'b0101, 3'b001, 3'b000, 6'b000101};
            // Addr 12: ADDI R2, R0, 5 -> R2 = 5 (same as R1)
            8'd12: instr = {4'b0101, 3'b010, 3'b000, 6'b000101};
            // Addr 13: BEQ R1, R2, +2 -> R1=5, R2=5, EQUAL -> branch to addr 15
            8'd13: instr = {4'b1000, 3'b001, 3'b010, 6'b000010};
            // Addr 14: ADDI R3, R0, 63 -> FLUSHED (must NOT execute)
            8'd14: instr = {4'b0101, 3'b011, 3'b000, 6'b111111};
            // Addr 15: ADDI R4, R0, 7 -> R4 = 7 (branch lands here)
            8'd15: instr = {4'b0101, 3'b100, 3'b000, 6'b000111};
            // Addr 16-17: NOP
            8'd16: instr = 16'b1001_000_000_000_000;
            8'd17: instr = 16'b1001_000_000_000_000;
            // All other addresses: NOP
            default: instr = 16'b1001_000_000_000_000;
        endcase
    end
endmodule



// MODULE 3: IF/ID PIPELINE REGISTER

module if_id_reg (
    input        clk, rst,
    input        stall,       // Freeze register on stall
    input        flush,       // Clear on branch taken
    input [15:0] pc_in,
    input [15:0] instr_in,
    output reg [15:0] pc_out,
    output reg [15:0] instr_out
);
    always @(posedge clk or posedge rst) begin
        if (rst || flush) begin
            pc_out    <= 16'd0;
            instr_out <= 16'b1001_000_000_000_000; // NOP bubble
        end else if (!stall) begin
            pc_out    <= pc_in;
            instr_out <= instr_in;
        end
        // If stall, hold previous values
    end
endmodule



// MODULE 4: REGISTER FILE (8 x 16-bit, R0 = always 0)

module register_file (
    input        clk, rst,
    input        reg_write,       // Write enable (from WB stage)
    input  [2:0] rs1, rs2,        // Read ports
    input  [2:0] rd_write,        // Write address or Destination address (from WB)
    input [15:0] write_data,      // Data to be written in Destination register (from WB)
    output [15:0] read_data1,
    output [15:0] read_data2
);
    reg [15:0] registers [0:7];
    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1)
                registers[i] <= 16'd0;
        end else if (reg_write && (rd_write != 3'd0)) begin
            // R0 is hardwired to 0, never written
            registers[rd_write] <= write_data;
        end
    end

    // Asynchronous reads
    assign read_data1 = (rs1 == 3'd0) ? 16'd0 : registers[rs1];
    assign read_data2 = (rs2 == 3'd0) ? 16'd0 : registers[rs2];
endmodule



// MODULE 5: CONTROL UNIT

module control_unit (
    input  [3:0] opcode,
    output reg   reg_write,    // 1 = write result to register file
    output reg   mem_read,     // 1 = read from data memory (LOAD)
    output reg   mem_write,    // 1 = write to data memory (STORE)
    output reg   mem_to_reg,   // 1 = WB data from memory, 0 = from ALU
    output reg   alu_src,      // 0 = register, 1 = immediate
    output reg   branch,       // 1 = BEQ instruction
    output reg [2:0] alu_op    // ALU operation select
);
    // ALU Operations
    // 3'b000 = ADD   3'b001 = SUB   3'b010 = AND
    // 3'b011 = OR    3'b100 = XOR   3'b101 = PASS_A (for STORE address)

    always @(*) begin
        // Safe defaults - prevents latches
        reg_write  = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        mem_to_reg = 1'b0;
        alu_src    = 1'b0;
        branch     = 1'b0;
        alu_op     = 3'b000;

        case (opcode)
            4'b0000: begin // ADD rd, rs1, rs2
                reg_write = 1'b1;
                alu_op    = 3'b000;
            end
            4'b0001: begin // SUB rd, rs1, rs2
                reg_write = 1'b1;
                alu_op    = 3'b001;
            end
            4'b0010: begin // AND rd, rs1, rs2
                reg_write = 1'b1;
                alu_op    = 3'b010;
            end
            4'b0011: begin // OR rd, rs1, rs2
                reg_write = 1'b1;
                alu_op    = 3'b011;
            end
            4'b0100: begin // XOR rd, rs1, rs2
                reg_write = 1'b1;
                alu_op    = 3'b100;
            end
            4'b0101: begin // ADDI rd, rs1, imm6
                reg_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = 3'b000;
            end
            4'b0110: begin // LOAD rd, rs1, imm6
                reg_write  = 1'b1;
                mem_read   = 1'b1;
                mem_to_reg = 1'b1;
                alu_src    = 1'b1;   // Address = rs1 + imm6
                alu_op     = 3'b000;
            end
            4'b0111: begin // STORE rs1, rs2 (mem[rs1] = rs2)
                mem_write = 1'b1;
                alu_op    = 3'b101; // PASS_A: address = rs1
            end
            4'b1000: begin // BEQ rs1, rs2, imm6
                branch  = 1'b1;
                alu_op  = 3'b001; // SUB to check equality
            end
            4'b1001: begin // NOP - all signals stay default 0
            end
            default: begin // Unknown opcode - safe NOP behavior
            end
        endcase
    end
endmodule



// MODULE 6: SIGN EXTENDER (6-bit -> 16-bit, signed)

module sign_extend (
    input  [5:0]  imm6,
    output [15:0] imm16
);
    assign imm16 = {{10{imm6[5]}}, imm6};
endmodule



// MODULE 7: ID/EX PIPELINE REGISTER

module id_ex_reg (
    input clk, rst,
    input flush,                         // Insert bubble on load-use hazard
    // Control inputs
    input reg_write_in, mem_read_in, mem_write_in,
    input mem_to_reg_in, alu_src_in, branch_in,
    input [2:0] alu_op_in,
    // Data inputs
    input [15:0] pc_in,
    input [15:0] read_data1_in, read_data2_in,
    input [15:0] imm16_in,
    input [2:0]  rs1_in, rs2_in, rd_in,
    // Control outputs
    output reg reg_write_out, mem_read_out, mem_write_out,
    output reg mem_to_reg_out, alu_src_out, branch_out,
    output reg [2:0] alu_op_out,
    // Data outputs
    output reg [15:0] pc_out,
    output reg [15:0] read_data1_out, read_data2_out,
    output reg [15:0] imm16_out,
    output reg [2:0]  rs1_out, rs2_out, rd_out
);
    always @(posedge clk or posedge rst) begin
        if (rst || flush) begin
            // Insert NOP bubble - all control signals LOW
            reg_write_out   <= 1'b0;  mem_read_out    <= 1'b0;
            mem_write_out   <= 1'b0;  mem_to_reg_out  <= 1'b0;
            alu_src_out     <= 1'b0;  branch_out      <= 1'b0;
            alu_op_out      <= 3'b0;  pc_out          <= 16'b0;
            read_data1_out  <= 16'b0; read_data2_out  <= 16'b0;
            imm16_out       <= 16'b0;
            rs1_out         <= 3'b0;  rs2_out         <= 3'b0;
            rd_out          <= 3'b0;
        end else begin
            reg_write_out   <= reg_write_in;
            mem_read_out    <= mem_read_in;
            mem_write_out   <= mem_write_in;
            mem_to_reg_out  <= mem_to_reg_in;
            alu_src_out     <= alu_src_in;
            branch_out      <= branch_in;
            alu_op_out      <= alu_op_in;
            pc_out          <= pc_in;
            read_data1_out  <= read_data1_in;
            read_data2_out  <= read_data2_in;
            imm16_out       <= imm16_in;
            rs1_out         <= rs1_in;
            rs2_out         <= rs2_in;
            rd_out          <= rd_in;
        end
    end
endmodule



// MODULE 8: ALU

module alu (
    input  [15:0] a, b,
    input  [2:0]  alu_op,
    output reg [15:0] result,
    output zero               // 1 when result == 0 (used for BEQ)
);
    always @(*) begin
        case (alu_op)
            3'b000:  result = a + b;   // ADD / ADDI / LOAD address
            3'b001:  result = a - b;   // SUB / BEQ comparison
            3'b010:  result = a & b;   // AND
            3'b011:  result = a | b;   // OR
            3'b100:  result = a ^ b;   // XOR
            3'b101:  result = a;       // PASS_A - STORE address = rs1
            default: result = 16'd0;
        endcase
    end
    assign zero = (result == 16'd0) ? 1'b1 : 1'b0;
endmodule



// MODULE 9: EX/MEM PIPELINE REGISTER

module ex_mem_reg (
    input clk, rst,
    // Control inputs
    input reg_write_in, mem_read_in, mem_write_in, mem_to_reg_in, branch_in,
    // Data inputs
    input [15:0] branch_target_in,
    input        zero_in,
    input [15:0] alu_result_in,
    input [15:0] write_data_in,   // rs2 data forwarded - for STORE
    input [2:0]  rd_in,
    // Control outputs
    output reg reg_write_out, mem_read_out, mem_write_out, mem_to_reg_out, branch_out,
    // Data outputs
    output reg [15:0] branch_target_out,
    output reg        zero_out,
    output reg [15:0] alu_result_out,
    output reg [15:0] write_data_out,
    output reg [2:0]  rd_out
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            reg_write_out     <= 1'b0;  mem_read_out      <= 1'b0;
            mem_write_out     <= 1'b0;  mem_to_reg_out    <= 1'b0;
            branch_out        <= 1'b0;  branch_target_out <= 16'b0;
            zero_out          <= 1'b0;  alu_result_out    <= 16'b0;
            write_data_out    <= 16'b0; rd_out            <= 3'b0;
        end else begin
            reg_write_out     <= reg_write_in;
            mem_read_out      <= mem_read_in;
            mem_write_out     <= mem_write_in;
            mem_to_reg_out    <= mem_to_reg_in;
            branch_out        <= branch_in;
            branch_target_out <= branch_target_in;
            zero_out          <= zero_in;
            alu_result_out    <= alu_result_in;
            write_data_out    <= write_data_in;
            rd_out            <= rd_in;
        end
    end
endmodule



// MODULE 10: DATA MEMORY (synthesizable RAM, word-addressed)
// Synchronous write, synchronous read - Vivado infers as Block RAM
// No initial block - memory starts at 0 by FPGA default

module data_memory (
    input        clk,
    input        mem_read, mem_write,
    input [15:0] address,
    input [15:0] write_data,
    output reg [15:0] read_data
);
    reg [15:0] dmem [0:255];

    // Synchronous write
    always @(posedge clk) begin
        if (mem_write)
            dmem[address[7:0]] <= write_data;
    end

    // Synchronous read - required for Block RAM inference
    always @(posedge clk) begin
        if (mem_read)
            read_data <= dmem[address[7:0]];
        else
            read_data <= 16'd0;
    end
endmodule



// MODULE 11: MEM/WB PIPELINE REGISTER

module mem_wb_reg (
    input clk, rst,
    // Control
    input reg_write_in, mem_to_reg_in,
    // Data
    input [15:0] mem_data_in,
    input [15:0] alu_result_in,
    input [2:0]  rd_in,
    // Outputs
    output reg reg_write_out, mem_to_reg_out,
    output reg [15:0] mem_data_out,
    output reg [15:0] alu_result_out,
    output reg [2:0]  rd_out
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            reg_write_out   <= 1'b0;  mem_to_reg_out  <= 1'b0;
            mem_data_out    <= 16'b0; alu_result_out  <= 16'b0;
            rd_out          <= 3'b0;
        end else begin
            reg_write_out   <= reg_write_in;
            mem_to_reg_out  <= mem_to_reg_in;
            mem_data_out    <= mem_data_in;
            alu_result_out  <= alu_result_in;
            rd_out          <= rd_in;
        end
    end
endmodule



// MODULE 12: FORWARDING UNIT
// Resolves RAW (Read After Write) data hazards via bypassing
// 
// forward_x = 2'b00 -> No forwarding: use register file output
// forward_x = 2'b01 -> Forward from WB stage  (2-cycle-old result)
// forward_x = 2'b10 -> Forward from MEM stage (1-cycle-old result)
// MEM-stage forwarding takes priority over WB-stage forwarding

module forwarding_unit (
    input [2:0] ex_rs1,       // Source reg 1 in EX stage
    input [2:0] ex_rs2,       // Source reg 2 in EX stage
    input [2:0] mem_rd,       // Destination reg in MEM stage
    input       mem_reg_write,
    input [2:0] wb_rd,        // Destination reg in WB stage
    input       wb_reg_write,
    output reg [1:0] forward_a, // Forwarding select for ALU input A
    output reg [1:0] forward_b  // Forwarding select for ALU input B
);
    always @(*) begin
        forward_a = 2'b00;
        forward_b = 2'b00;

        // Forward A 
        // MEM-stage hazard (higher priority)
        if (mem_reg_write && (mem_rd != 3'd0) && (mem_rd == ex_rs1))
            forward_a = 2'b10;
        // WB-stage hazard (lower priority, only if MEM doesn't already forward)
        else if (wb_reg_write && (wb_rd != 3'd0) && (wb_rd == ex_rs1))
            forward_a = 2'b01;

        // Forward B
        if (mem_reg_write && (mem_rd != 3'd0) && (mem_rd == ex_rs2))
            forward_b = 2'b10;
        else if (wb_reg_write && (wb_rd != 3'd0) && (wb_rd == ex_rs2))
            forward_b = 2'b01;
    end
endmodule



// MODULE 13: HAZARD DETECTION UNIT
// Detects load-use hazard: LOAD in EX, dependent instruction in ID
// Solution: stall pipeline for 1 cycle + insert NOP bubble

module hazard_detection_unit (
    input [2:0] id_rs1, id_rs2,  // Source regs of instruction in ID
    input [2:0] ex_rd,            // Destination reg of instruction in EX
    input       ex_mem_read,      // Is EX stage a LOAD instruction?
    output reg  stall,            // 1 = freeze PC + IF/ID register
    output reg  flush_id_ex       // 1 = insert NOP bubble into ID/EX
);
    always @(*) begin
        if (ex_mem_read &&
            ((ex_rd == id_rs1) || (ex_rd == id_rs2)) &&
            (ex_rd != 3'd0)) begin
            stall       = 1'b1; // Hold PC and IF/ID
            flush_id_ex = 1'b1; // Insert bubble (NOP) into ID/EX
        end else begin
            stall       = 1'b0;
            flush_id_ex = 1'b0;
        end
    end
endmodule



// MODULE 14: TOP-LEVEL - 5-STAGE PIPELINED RISC PROCESSOR

module risc_pipeline_top (
    input clk,
    input rst,
    output [15:0] pc_out,
    output [15:0] alu_out,
    output stall_out
);

    // WIRE DECLARATIONS
    

    //  IF Stage 
    wire [15:0] pc_current, pc_plus1, pc_next;
    wire [15:0] instr_if;
    wire        branch_taken;
    wire        stall;

    //  IF/ID Register Outputs 
    wire [15:0] if_id_pc, if_id_instr;

    //  ID Stage 
    wire [3:0]  opcode_id;
    wire [2:0]  rd_id, rs1_id, rs2_id;
    wire [5:0]  imm6_id;
    wire [15:0] imm16_id;
    wire [15:0] reg_data1, reg_data2;
    wire        flush_if_id;
    wire        flush_id_ex;
    // Control signals from control unit
    wire        ctrl_reg_write, ctrl_mem_read, ctrl_mem_write;
    wire        ctrl_mem_to_reg, ctrl_alu_src, ctrl_branch;
    wire [2:0]  ctrl_alu_op;

    //  ID/EX Register Outputs 
    wire        id_ex_reg_write, id_ex_mem_read, id_ex_mem_write;
    wire        id_ex_mem_to_reg, id_ex_alu_src, id_ex_branch;
    wire [2:0]  id_ex_alu_op;
    wire [15:0] id_ex_pc;
    wire [15:0] id_ex_data1, id_ex_data2, id_ex_imm16;
    wire [2:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;

    //  EX Stage 
    wire [1:0]  forward_a, forward_b;
    wire [15:0] alu_in_a, alu_in_b_mux, alu_in_b;
    wire [15:0] alu_result_ex;
    wire        alu_zero;
    wire [15:0] branch_target_ex;

    //  EX/MEM Register Outputs 
    wire        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;
    wire        ex_mem_mem_to_reg, ex_mem_branch;
    wire [15:0] ex_mem_branch_target;
    wire        ex_mem_zero;
    wire [15:0] ex_mem_alu_result, ex_mem_write_data;
    wire [2:0]  ex_mem_rd;

    //  MEM Stage 
    wire [15:0] mem_read_data;

    //  MEM/WB Register Outputs 
    wire        mem_wb_reg_write, mem_wb_mem_to_reg;
    wire [15:0] mem_wb_mem_data, mem_wb_alu_result;
    wire [2:0]  mem_wb_rd;

    //  WB Stage 
    wire [15:0] wb_write_data;


    
    // STAGE 1: INSTRUCTION FETCH (IF)
    

    // PC mux: normal increment or branch target
    assign pc_plus1     = pc_current + 16'd1;
    assign branch_taken = ex_mem_branch & ex_mem_zero; // BEQ taken when zero flag set
    assign pc_next      = branch_taken ? ex_mem_branch_target : pc_plus1;

    // Flush IF/ID when branch is taken (discard wrongly fetched instruction)
    assign flush_if_id  = branch_taken;

    program_counter PC (
        .clk     (clk),
        .rst     (rst),
        .stall   (stall),
        .pc_next (pc_next),
        .pc      (pc_current)
    );

    instruction_memory IMEM (
        .pc          (pc_current),
        .instr (instr_if)
    );

    if_id_reg IF_ID (
        .clk      (clk),
        .rst      (rst),
        .stall    (stall),
        .flush    (flush_if_id),
        .pc_in    (pc_current),
        .instr_in (instr_if),
        .pc_out   (if_id_pc),
        .instr_out(if_id_instr)
    );


    
    // STAGE 2: INSTRUCTION DECODE (ID)
    

    // Decode instruction fields
    assign opcode_id = if_id_instr[15:12];
    assign rd_id     = if_id_instr[11:9];
    assign rs1_id    = if_id_instr[8:6];
    assign rs2_id    = if_id_instr[5:3];
    assign imm6_id   = if_id_instr[5:0];

    control_unit CU (
        .opcode     (opcode_id),
        .reg_write  (ctrl_reg_write),
        .mem_read   (ctrl_mem_read),
        .mem_write  (ctrl_mem_write),
        .mem_to_reg (ctrl_mem_to_reg),
        .alu_src    (ctrl_alu_src),
        .branch     (ctrl_branch),
        .alu_op     (ctrl_alu_op)
    );

    sign_extend SE (
        .imm6  (imm6_id),
        .imm16 (imm16_id)
    );

    // Register file: read in ID, write from WB (same cycle)
    register_file RF (
        .clk        (clk),
        .rst        (rst),
        .reg_write  (mem_wb_reg_write),   // WB write-enable
        .rs1        (rs1_id),
        .rs2        (rs2_id),
        .rd_write   (mem_wb_rd),          // WB destination
        .write_data (wb_write_data),      // WB data
        .read_data1 (reg_data1),
        .read_data2 (reg_data2)
    );

    hazard_detection_unit HDU (
        .id_rs1      (rs1_id),
        .id_rs2      (rs2_id),
        .ex_rd       (id_ex_rd),
        .ex_mem_read (id_ex_mem_read),
        .stall       (stall),
        .flush_id_ex (flush_id_ex)
    );

    id_ex_reg ID_EX (
        .clk             (clk),
        .rst             (rst),
        .flush           (flush_id_ex),
        .reg_write_in    (ctrl_reg_write),
        .mem_read_in     (ctrl_mem_read),
        .mem_write_in    (ctrl_mem_write),
        .mem_to_reg_in   (ctrl_mem_to_reg),
        .alu_src_in      (ctrl_alu_src),
        .branch_in       (ctrl_branch),
        .alu_op_in       (ctrl_alu_op),
        .pc_in           (if_id_pc),
        .read_data1_in   (reg_data1),
        .read_data2_in   (reg_data2),
        .imm16_in        (imm16_id),
        .rs1_in          (rs1_id),
        .rs2_in          (rs2_id),
        .rd_in           (rd_id),
        .reg_write_out   (id_ex_reg_write),
        .mem_read_out    (id_ex_mem_read),
        .mem_write_out   (id_ex_mem_write),
        .mem_to_reg_out  (id_ex_mem_to_reg),
        .alu_src_out     (id_ex_alu_src),
        .branch_out      (id_ex_branch),
        .alu_op_out      (id_ex_alu_op),
        .pc_out          (id_ex_pc),
        .read_data1_out  (id_ex_data1),
        .read_data2_out  (id_ex_data2),
        .imm16_out       (id_ex_imm16),
        .rs1_out         (id_ex_rs1),
        .rs2_out         (id_ex_rs2),
        .rd_out          (id_ex_rd)
    );


    
    // STAGE 3: EXECUTE (EX)
    

    forwarding_unit FWD (
        .ex_rs1       (id_ex_rs1),
        .ex_rs2       (id_ex_rs2),
        .mem_rd       (ex_mem_rd),
        .mem_reg_write(ex_mem_reg_write),
        .wb_rd        (mem_wb_rd),
        .wb_reg_write (mem_wb_reg_write),
        .forward_a    (forward_a),
        .forward_b    (forward_b)
    );

    // Forward mux for ALU input A
    assign alu_in_a = (forward_a == 2'b10) ? ex_mem_alu_result :
                      (forward_a == 2'b01) ? wb_write_data     :
                                             id_ex_data1;

    // Forward mux for ALU input B (register value, pre-immediate mux)
    assign alu_in_b_mux = (forward_b == 2'b10) ? ex_mem_alu_result :
                          (forward_b == 2'b01) ? wb_write_data     :
                                                 id_ex_data2;

    // ALU source mux: immediate or register
    // For R-type and BEQ: alu_in_b = register value
    // For ADDI, LOAD:     alu_in_b = sign-extended immediate
    // For STORE:          alu_src=0, alu_op=PASS_A, so alu_in_b irrelevant for address
    assign alu_in_b = id_ex_alu_src ? id_ex_imm16 : alu_in_b_mux;

    // Branch target = PC of branch instruction + sign-extended offset
    assign branch_target_ex = id_ex_pc + id_ex_imm16;

    alu ALU (
        .a      (alu_in_a),
        .b      (alu_in_b),
        .alu_op (id_ex_alu_op),
        .result (alu_result_ex),
        .zero   (alu_zero)
    );

    ex_mem_reg EX_MEM (
        .clk              (clk),
        .rst              (rst),
        .reg_write_in     (id_ex_reg_write),
        .mem_read_in      (id_ex_mem_read),
        .mem_write_in     (id_ex_mem_write),
        .mem_to_reg_in    (id_ex_mem_to_reg),
        .branch_in        (id_ex_branch),
        .branch_target_in (branch_target_ex),
        .zero_in          (alu_zero),
        .alu_result_in    (alu_result_ex),
        .write_data_in    (alu_in_b_mux),  // Forwarded rs2 - used as STORE data
        .rd_in            (id_ex_rd),
        .reg_write_out    (ex_mem_reg_write),
        .mem_read_out     (ex_mem_mem_read),
        .mem_write_out    (ex_mem_mem_write),
        .mem_to_reg_out   (ex_mem_mem_to_reg),
        .branch_out       (ex_mem_branch),
        .branch_target_out(ex_mem_branch_target),
        .zero_out         (ex_mem_zero),
        .alu_result_out   (ex_mem_alu_result),
        .write_data_out   (ex_mem_write_data),
        .rd_out           (ex_mem_rd)
    );


    
    // STAGE 4: MEMORY ACCESS (MEM)
    

    data_memory DMEM (
        .clk        (clk),
        .mem_read   (ex_mem_mem_read),
        .mem_write  (ex_mem_mem_write),
        .address    (ex_mem_alu_result),   // Address from ALU
        .write_data (ex_mem_write_data),   // Data to store (rs2)
        .read_data  (mem_read_data)
    );

    mem_wb_reg MEM_WB (
        .clk            (clk),
        .rst            (rst),
        .reg_write_in   (ex_mem_reg_write),
        .mem_to_reg_in  (ex_mem_mem_to_reg),
        .mem_data_in    (mem_read_data),
        .alu_result_in  (ex_mem_alu_result),
        .rd_in          (ex_mem_rd),
        .reg_write_out  (mem_wb_reg_write),
        .mem_to_reg_out (mem_wb_mem_to_reg),
        .mem_data_out   (mem_wb_mem_data),
        .alu_result_out (mem_wb_alu_result),
        .rd_out         (mem_wb_rd)
    );


    
    // STAGE 5: WRITE BACK (WB)
    

    // Select between memory data (LOAD) or ALU result
    assign wb_write_data = mem_wb_mem_to_reg ? mem_wb_mem_data
                                             : mem_wb_alu_result;

    // wb_write_data and mem_wb_reg_write feed back to register_file
    // (already connected in Stage 2 above)
    
    assign pc_out   = pc_current;
    assign alu_out  = alu_result_ex; 
    assign stall_out = stall;

endmodule
