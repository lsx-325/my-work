`timescale 1ns / 1ps

module tb_weight_bram_controller;

    // =========================================================================
    // 1. 参数定义 (保持与设计模块一致)
    // =========================================================================
    parameter AXIS_DATA_WIDTH = 64;
    parameter NUM_CHANNELS    = 8;
    parameter DATA_WIDTH      = 8;
    parameter FILTER_SIZE     = 3;
    parameter BRAM_DEPTH      = 512;
    
    // 派生参数
    localparam KERNEL_SET_WIDTH = NUM_CHANNELS * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH; // 576
    localparam BRAM_LINE_WIDTH  = 2 * KERNEL_SET_WIDTH; // 1152
    localparam BEATS_PER_LINE   = BRAM_LINE_WIDTH / AXIS_DATA_WIDTH; // 18

    // =========================================================================
    // 2. 信号定义
    // =========================================================================
    reg clk;
    reg rst_n;

    // AXI Stream 写接口
    reg                       s_axis_tvalid;
    wire                      s_axis_tready;
    reg [AXIS_DATA_WIDTH-1:0] s_axis_tdata;
    reg                       s_axis_tlast;
    
    // 控制接口
    reg                       i_write_addr_rst;
    reg [$clog2(BRAM_DEPTH)-1:0] i_read_addr;
    reg                       i_read_en;

    // 输出接口
    wire [KERNEL_SET_WIDTH-1:0] o_kernels_A_packed;
    wire [KERNEL_SET_WIDTH-1:0] o_kernels_B_packed;

    // 验证辅助变量
    reg [BRAM_LINE_WIDTH-1:0] expected_line_0;
    reg [BRAM_LINE_WIDTH-1:0] expected_line_1;
    reg [BRAM_LINE_WIDTH-1:0] read_data_combined;

    // =========================================================================
    // 3. 待测模块实例化 (DUT)
    // =========================================================================
    weight_bram_controller #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .NUM_CHANNELS   (NUM_CHANNELS),
        .DATA_WIDTH     (DATA_WIDTH),
        .FILTER_SIZE    (FILTER_SIZE),
        .BRAM_DEPTH     (BRAM_DEPTH)
    ) u_dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .s_axis_tvalid      (s_axis_tvalid),
        .s_axis_tready      (s_axis_tready),
        .s_axis_tdata       (s_axis_tdata),
        .s_axis_tlast       (s_axis_tlast),
        .i_write_addr_rst   (i_write_addr_rst),
        .i_read_addr        (i_read_addr),
        .i_read_en          (i_read_en),
        .o_kernels_A_packed (o_kernels_A_packed),
        .o_kernels_B_packed (o_kernels_B_packed)
    );

    // =========================================================================
    // 4. 时钟生成 (100MHz)
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 5. 主测试流程
    // =========================================================================
    integer i, j;
    
    initial begin
        // --- 初始化 ---
        rst_n = 0;
        s_axis_tvalid = 0;
        s_axis_tdata = 0;
        s_axis_tlast = 0;
        i_write_addr_rst = 0;
        i_read_addr = 0;
        i_read_en = 0;
        expected_line_0 = 0;
        expected_line_1 = 0;

        // --- 复位释放 ---
        #100;
        rst_n = 1;
        #20;

        $display("\n=== TEST START: Weight BRAM Controller Verification ===\n");

        // ---------------------------------------------------------------------
        // 测试阶段 1: 写入数据 (Write Phase)
        // ---------------------------------------------------------------------
        $display("[Time %0t] Phase 1: Starting AXI Stream Write...", $time);

        // 1. 复位写地址
        @(posedge clk);
        i_write_addr_rst = 1;
        @(posedge clk);
        i_write_addr_rst = 0;
        #10;

        // 2. 写入第一行数据 (Address 0)
        // 模拟发送 18 个 64-bit 数据包
        for (i = 0; i < BEATS_PER_LINE; i = i + 1) begin
            @(posedge clk);
            s_axis_tvalid = 1;
            // 构造测试数据：例如 64'h00...01, 64'h00...02
            s_axis_tdata  = i + 1; 
            if (i == BEATS_PER_LINE - 1) s_axis_tlast = 1;
            else s_axis_tlast = 0;

            // 构造期望数据用于对比 (低位先发，放入低位)
            // 注意 Verilog 的切片赋值
            expected_line_0[i*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] = i + 1;

            // 等待握手
            wait(s_axis_tready);
        end
        
        @(posedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        $display("[Time %0t] Written Line 0 complete.", $time);
        #20;

        // 3. 写入第二行数据 (Address 1)
        // 数据 pattern 变一下，方便区分 (例如从 0xA0 开始)
        for (i = 0; i < BEATS_PER_LINE; i = i + 1) begin
            @(posedge clk);
            s_axis_tvalid = 1;
            s_axis_tdata  = 8'hA0 + i; 
            if (i == BEATS_PER_LINE - 1) s_axis_tlast = 1;
            else s_axis_tlast = 0;

            expected_line_1[i*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] = 8'hA0 + i;

            wait(s_axis_tready);
        end

        @(posedge clk);
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        $display("[Time %0t] Written Line 1 complete.", $time);
        #50;

        // ---------------------------------------------------------------------
        // 测试阶段 2: 读取数据 (Read Phase)
        // ---------------------------------------------------------------------
        $display("\n[Time %0t] Phase 2: Starting BRAM Read Check...", $time);

        // 1. 读取地址 0
        @(posedge clk);
        i_read_en = 1;
        i_read_addr = 0;
        
        // 等待 1 个周期 (因为 BRAM 读通常有 1 cycle latency)
        @(posedge clk); 
        #1; // 用于观察波形，错开一点时间

        // 拼接读出的 A 和 B 用于对比
        read_data_combined = {o_kernels_B_packed, o_kernels_A_packed};

        // 自动对比
        if (read_data_combined === expected_line_0) begin
            $display("[PASS] Address 0 Data Match!");
        end else begin
            $display("[FAIL] Address 0 Mismatch!");
            $display("Expected: %h", expected_line_0);
            $display("Actual  : %h", read_data_combined);
        end

        // 2. 读取地址 1
        @(posedge clk);
        i_read_addr = 1;
        
        @(posedge clk); // 等待数据更新
        #1;

        read_data_combined = {o_kernels_B_packed, o_kernels_A_packed};

        if (read_data_combined === expected_line_1) begin
            $display("[PASS] Address 1 Data Match!");
        end else begin
            $display("[FAIL] Address 1 Mismatch!");
            $display("Expected: %h", expected_line_1);
            $display("Actual  : %h", read_data_combined);
        end

        // 3. 停止读取
        @(posedge clk);
        i_read_en = 0;

        #50;
        $display("\n=== TEST COMPLETE ===");
        $stop;
    end

endmodule