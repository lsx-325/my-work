`timescale 1ns / 1ps

module tb_dsp_slice_3x3;

    // =========================================================
    // 1. 固定参数定义 (3x3 专用)
    // =========================================================
    parameter ACCUM_WIDTH = 32;
    parameter DATA_WIDTH  = 8;
    parameter FILTER_SIZE = 3; 
    
    // 3x3 = 9个点, 9 * 8bit = 72bit
    localparam TOTAL_BITS = 72; 

    // =========================================================
    // 2. 信号定义
    // =========================================================
    reg                               clk;
    reg                               rst_n;
    reg                               i_valid;
    
    // 输入信号 (72位宽)
    reg  signed [TOTAL_BITS-1:0]      i_window_packed;
    reg  signed [TOTAL_BITS-1:0]      i_kernel_A_packed;
    reg  signed [TOTAL_BITS-1:0]      i_kernel_B_packed;

    // 输出信号
    wire signed [ACCUM_WIDTH-1:0]     o_sum_A;
    wire signed [ACCUM_WIDTH-1:0]     o_sum_B;
    wire                              o_valid_out;

    // =========================================================
    // 3. 实例化 DUT
    // =========================================================
    dsp_slice_2x_output #(
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .FILTER_SIZE(3)  // 固定为 3
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_valid          (i_valid),
        .i_window_packed  (i_window_packed),
        .i_kernel_A_packed(i_kernel_A_packed),
        .i_kernel_B_packed(i_kernel_B_packed),
        .o_sum_A          (o_sum_A),
        .o_sum_B          (o_sum_B),
        .o_valid_out      (o_valid_out)
    );

    // =========================================================
    // 4. 辅助函数：打包9个字节 (辅助生成测试数据)
    // =========================================================
    function [71:0] pack_9;
        input signed [7:0] d8, d7, d6, d5, d4, d3, d2, d1, d0;
        begin
            // 高位对应最新数据 (Row2), 低位对应旧数据 (Row0)
            pack_9 = {d8, d7, d6, d5, d4, d3, d2, d1, d0};
        end
    endfunction

    // =========================================================
    // 5. 验证逻辑：预期值队列 (FIFO)
    // =========================================================
    reg signed [ACCUM_WIDTH-1:0] q_exp_A [0:31];
    reg signed [ACCUM_WIDTH-1:0] q_exp_B [0:31];
    integer q_wr = 0;
    integer q_rd = 0;
    integer err_cnt = 0;

    // 发送任务
    task send_3x3;
        input signed [71:0] win;
        input signed [71:0] kA;
        input signed [71:0] kB;
        integer k;
        reg signed [31:0] sum_a, sum_b;
        begin
            // 1. 驱动输入
            i_valid <= 1;
            i_window_packed   <= win;
            i_kernel_A_packed <= kA;
            i_kernel_B_packed <= kB;

            // 2. 计算预期值 (Golden Model)
            sum_a = 0; sum_b = 0;
            for(k=0; k<9; k=k+1) begin
                sum_a = sum_a + $signed(win[k*8+:8]) * $signed(kA[k*8+:8]);
                sum_b = sum_b + $signed(win[k*8+:8]) * $signed(kB[k*8+:8]);
            end

            // 3. 存入队列
            q_exp_A[q_wr] = sum_a;
            q_exp_B[q_wr] = sum_b;
            q_wr = (q_wr + 1) % 32;

            @(posedge clk);
        end
    endtask

    // =========================================================
    // 6. 主测试流程
    // =========================================================
    initial begin
        clk = 0;
        rst_n = 0;
        i_valid = 0;
        i_window_packed = 0;
        i_kernel_A_packed = 0;
        i_kernel_B_packed = 0;
        
        #20;
        rst_n = 1;
        #20;

        $display("=== [TEST START] 3x3 Fixed Testbench ===");

        // --- Case 1: 全1测试 ---
        // 窗口全1, 卷积核A全1, 卷积核B全2
        // 预期 A = 9, B = 18
send_3x3(
    pack_9(100, 100, 100, 100, 100, 100, 100, 100, 100), // D = 100
    pack_9( -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1), // WA = -1 (负责"挖坑")
    pack_9(-128,-128,0,0,0,0,0,0,0) // WB = -128 (站在"悬崖边")
);

        // --- Case 2: 递增序列测试 ---
        // 窗口: 9,8,7...1
        // 核A:  1,1,1...1 => Sum A = 45
        // 核B:  0,0,0...0 => Sum B = 0
        send_3x3(
            pack_9(9,8,7,6,5,4,3,2,1),
            pack_9(1,1,1,1,1,1,1,1,1),
            pack_9(0,0,0,0,0,0,0,0,0)
        );

        // --- Case 3: 正负数混合 ---
        // 窗口: 1, -1, 1, -1 ...
        // 核A:  10 ...
        // 预期: 1*10 + (-1)*10 ...
        send_3x3(
            pack_9( 1, -1,  1, -1,  1, -1,  1, -1,  1),
            pack_9(10, 10, 10, 10, 10, 10, 10, 10, 10),
            pack_9( 1,  2,  1,  2,  1,  2,  1,  2,  1)
        );

        // 停止输入
        i_valid <= 0;
        
        // 等待输出排空
        #200;
        
        if (err_cnt == 0) 
            $display("=== [PASS] All 3x3 tests passed! ===");
        else 
            $display("=== [FAIL] Found %0d mismatches! ===", err_cnt);
            
        $finish;
    end

    // 时钟生成
    always #5 clk = ~clk;

    // =========================================================
    // 7. 自动检查器 (Checker)
    // =========================================================
    always @(posedge clk) begin
        if (rst_n && o_valid_out) begin
            // 采样时刻微小延迟
            
            if (o_sum_A !== q_exp_A[q_rd] || o_sum_B !== q_exp_B[q_rd]) begin
                $display("[ERROR @ %0t] Output Mismatch!", $time);
                $display("  Sum A: Real=%d, Exp=%d", o_sum_A, q_exp_A[q_rd]);
                $display("  Sum B: Real=%d, Exp=%d", o_sum_B, q_exp_B[q_rd]);
                err_cnt = err_cnt + 1;
            end else begin
                $display("[PASS @ %0t] Sum A=%d, Sum B=%d", $time, o_sum_A, o_sum_B);
            end
            
            q_rd = (q_rd + 1) % 32;
        end
    end

endmodule