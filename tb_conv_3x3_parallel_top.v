`timescale 1ns / 1ps

module tb_conv_3x3_parallel_top;

    // =========================================================
    // 1. 参数配置 (需与 RTL 顶层保持一致)
    // =========================================================
    parameter NUM_CHANNELS = 8;   // 8个并行通道
    parameter DATA_WIDTH   = 8;   // 8-bit 数据
    parameter ACCUM_WIDTH  = 32;  // 32-bit 累加
    parameter FILTER_SIZE  = 3;   // 3x3 卷积

    // 自动计算位宽
    localparam NUM_POINTS = FILTER_SIZE * FILTER_SIZE; // 9
    localparam UNIT_BITS  = NUM_POINTS * DATA_WIDTH;   // 72 bit (单通道位宽)
    localparam TOTAL_IN_WIDTH = NUM_CHANNELS * UNIT_BITS; // 576 bit (总输入位宽)
    localparam OUT_WIDTH  = ACCUM_WIDTH + $clog2(NUM_CHANNELS); // 35 bit

    // =========================================================
    // 2. 信号定义
    // =========================================================
    reg                                   clk;
    reg                                   rst_n;
    reg                                   i_valid;
    
    // 宽总线输入
    reg [TOTAL_IN_WIDTH-1:0]              i_windows_packed;
    reg [TOTAL_IN_WIDTH-1:0]              i_kernels_A_packed;
    reg [TOTAL_IN_WIDTH-1:0]              i_kernels_B_packed;

    // 输出
    wire signed [OUT_WIDTH-1:0]           o_final_sum_A;
    wire signed [OUT_WIDTH-1:0]           o_final_sum_B;
    wire                                  o_final_valid;

    // =========================================================
    // 3. 实例化 DUT (Device Under Test)
    // =========================================================
    conv_3x3_parallel_top #(
        .NUM_CHANNELS(NUM_CHANNELS),
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .FILTER_SIZE (FILTER_SIZE)
    ) u_dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .i_valid             (i_valid),
        .i_windows_packed    (i_windows_packed),
        .i_kernels_A_packed  (i_kernels_A_packed),
        .i_kernels_B_packed  (i_kernels_B_packed),
        .o_final_sum_A       (o_final_sum_A),
        .o_final_sum_B       (o_final_sum_B),
        .o_final_valid       (o_final_valid)
    );

    // =========================================================
    // 4. 时钟生成
    // =========================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // =========================================================
    // 5. 验证环境：预期值队列 (Scoreboard)
    // =========================================================
    reg signed [OUT_WIDTH-1:0] q_exp_A [0:255];
    reg signed [OUT_WIDTH-1:0] q_exp_B [0:255];
    integer q_wr = 0;
    integer q_rd = 0;
    integer err_cnt = 0;
    integer test_cnt = 0;

    // --- 辅助函数：计算单通道的点积 ---
    function signed [ACCUM_WIDTH-1:0] calc_single_ch_dot;
        input [UNIT_BITS-1:0] data;
        input [UNIT_BITS-1:0] weight;
        integer k;
        reg signed [DATA_WIDTH-1:0] d, w;
        reg signed [ACCUM_WIDTH-1:0] s;
        begin
            s = 0;
            for(k=0; k<NUM_POINTS; k=k+1) begin
                d = data  [k*DATA_WIDTH +: DATA_WIDTH];
                w = weight[k*DATA_WIDTH +: DATA_WIDTH];
                s = s + d * w;
            end
            calc_single_ch_dot = s;
        end
    endfunction

    // --- 任务：发送多通道测试数据 ---
    // 输入参数为简单的基数，任务内部自动生成复杂数据
    task send_multi_channel_packet;
        input integer mode; // 0:全1, 1:递增, 2:随机
        
        integer ch, p;
        reg [UNIT_BITS-1:0] ch_win, ch_kA, ch_kB;
        reg signed [ACCUM_WIDTH-1:0] ch_sum_A, ch_sum_B;
        reg signed [OUT_WIDTH-1:0] total_sum_A, total_sum_B;
        reg signed [DATA_WIDTH-1:0] val_win, val_ka, val_kb;
        begin
            total_sum_A = 0;
            total_sum_B = 0;

            // 遍历所有通道，生成数据并打包
            for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin
                ch_win = 0; ch_kA = 0; ch_kB = 0;
                
                // 生成单通道内的 9 个点
                for (p = 0; p < NUM_POINTS; p = p + 1) begin
                    if (mode == 0) begin // Case 0: 全 1
                        val_win = 1; val_ka = 1; val_kb = 2;
                    end else if (mode == 1) begin // Case 1: 通道号偏移
                        val_win = ch + 1; // Ch0=1, Ch1=2...
                        val_ka  = 1;
                        val_kb  = 0;
                    end else begin // Case 2: 随机
                        val_win = $random; val_ka = $random; val_kb = $random;
                    end

                    // 打包进单通道向量
                    ch_win[p*DATA_WIDTH +: DATA_WIDTH] = val_win;
                    ch_kA [p*DATA_WIDTH +: DATA_WIDTH] = val_ka;
                    ch_kB [p*DATA_WIDTH +: DATA_WIDTH] = val_kb;
                end

                // 将单通道向量填入总线
                i_windows_packed  [ch*UNIT_BITS +: UNIT_BITS] = ch_win;
                i_kernels_A_packed[ch*UNIT_BITS +: UNIT_BITS] = ch_kA;
                i_kernels_B_packed[ch*UNIT_BITS +: UNIT_BITS] = ch_kB;

                // 计算预期值 (软件模拟)
                ch_sum_A = calc_single_ch_dot(ch_win, ch_kA);
                ch_sum_B = calc_single_ch_dot(ch_win, ch_kB);
                
                // 累加所有通道
                total_sum_A = total_sum_A + ch_sum_A;
                total_sum_B = total_sum_B + ch_sum_B;
            end

            // 驱动信号
            i_valid <= 1;
            
            // 存入预期队列
            q_exp_A[q_wr] = total_sum_A;
            q_exp_B[q_wr] = total_sum_B;
            q_wr = (q_wr + 1) % 256;
            test_cnt = test_cnt + 1;

            @(posedge clk);
        end
    endtask

    // =========================================================
    // 6. 主测试流程
    // =========================================================
    integer i;
    initial begin
        rst_n = 0;
        i_valid = 0;
        i_windows_packed = 0;
        i_kernels_A_packed = 0;
        i_kernels_B_packed = 0;
        
        #20; rst_n = 1; #20;

        $display("=== [TEST START] Parallel Convolution Top (Channels=%0d) ===", NUM_CHANNELS);

        // --- Case 1: 基础全 1 测试 ---
        // 每个通道: Window=1, KA=1, KB=2 => SumA=9, SumB=18
        // 8个通道总和: A=72, B=144
        send_multi_channel_packet(0);

        // --- Case 2: 通道差异测试 ---
        // Ch0=1... Ch7=8
        // 验证通道间累加是否正确
        send_multi_channel_packet(1);

        // --- Case 3: 随机数据连发 ---
        $display("Sending 20 random packets...");
        for (i = 0; i < 20; i = i + 1) begin
            send_multi_channel_packet(2);
        end

        // 停止输入
        i_valid <= 0;
        
        // 等待结果流出
        wait(q_rd == q_wr);
        #100;

        if (err_cnt == 0)
            $display("=== [TEST PASS] All %0d packets matched! ===", test_cnt);
        else
            $display("=== [TEST FAIL] Found %0d errors! ===", err_cnt);
        
        $finish;
    end

    // =========================================================
    // 7. 自动检查器 (Checker)
    // =========================================================
    always @(negedge clk) begin
        if (rst_n && o_final_valid) begin
            #1; // 采样延迟
            
            if (o_final_sum_A !== q_exp_A[q_rd] || o_final_sum_B !== q_exp_B[q_rd]) begin
                $display("[ERROR @ %0t] Mismatch!", $time);
                $display("  Sum A: Real=%d, Exp=%d", o_final_sum_A, q_exp_A[q_rd]);
                $display("  Sum B: Real=%d, Exp=%d", o_final_sum_B, q_exp_B[q_rd]);
                err_cnt = err_cnt + 1;
            end else begin
                // $display("[PASS] A=%d, B=%d", o_final_sum_A, o_final_sum_B);
            end
            
            q_rd = (q_rd + 1) % 256;
        end
    end

endmodule