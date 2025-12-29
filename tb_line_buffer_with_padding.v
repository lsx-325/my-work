`timescale 1ns / 1ps

module tb_line_buffer_with_padding;

    // =================================================================
    // 1. 仿真参数定义 (缩小尺寸以便观察)
    // =================================================================
    parameter NUM_CHANNELS = 2;   // 测试2个通道，便于观察
    parameter DATA_WIDTH   = 8;
    parameter IMG_WIDTH    = 5;   // 5x5 的小图
    parameter IMG_HEIGHT   = 5;
    parameter FILTER_SIZE  = 3;
    
    // =================================================================
    // 2. 信号定义
    // =================================================================
    reg clk;
    reg rst_n;
    reg i_valid;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] i_data_parallel;
    
    wire o_valid;
    wire [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] o_windows_packed;

    // =================================================================
    // 3. 待测模块实例化 (DUT)
    // =================================================================
    line_buffer_with_padding #(
        .NUM_CHANNELS (NUM_CHANNELS),
        .DATA_WIDTH   (DATA_WIDTH),
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .FILTER_SIZE  (FILTER_SIZE)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_valid          (i_valid),
        .i_data_parallel  (i_data_parallel),
        .o_valid          (o_valid),
        .o_windows_packed (o_windows_packed)
    );

    // =================================================================
    // 4. 时钟生成
    // =================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10ns 周期
    end

    // =================================================================
    // 5. 测试激励 (Stimulus)
    // =================================================================
    integer r, c, ch;
    
    // 用于生成测试像素值的辅助函数： Channel 0 = row*10 + col, Channel 1 = 0xFF
    function [DATA_WIDTH-1:0] get_pixel_val(input integer row, input integer col, input integer chan);
        if (chan == 0)
            get_pixel_val = (row * 10) + col; // 通道0：直观的坐标值 (例如 12 代表第1行第2列)
        else
            get_pixel_val = 8'hFF;            // 通道1：全1，用于区分
    endfunction

    initial begin
        // --- 初始化 ---
        rst_n = 0;
        i_valid = 0;
        i_data_parallel = 0;
        
        // --- 开启波形记录 (如果使用 Vivado/ModelSim) ---
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_line_buffer_with_padding);

        // --- 复位释放 ---
        #20;
        rst_n = 1;
        #10;

        $display("-------------------------------------------------------------");
        $display("Simulation Start: Image Size %0dx%0d", IMG_WIDTH, IMG_HEIGHT);
        $display("-------------------------------------------------------------");

        // --- 逐行逐列发送像素 ---
        // 为了确保流水线完全输出，我们可能需要多发送一些无效周期或Flush，
        // 但根据你的逻辑，只要时钟在跑，行缓存就会流动。
        // 这里我们严格按照 5x5 发送数据。
        
        for (r = 0; r < IMG_HEIGHT; r = r + 1) begin
            for (c = 0; c < IMG_WIDTH; c = c + 1) begin
                
                // 构造多通道并行数据
                for (ch = 0; ch < NUM_CHANNELS; ch = ch + 1) begin
                    i_data_parallel[ch*DATA_WIDTH +: DATA_WIDTH] = get_pixel_val(r, c, ch);
                end
                
                i_valid = 1;
                
                // 打印输入日志
                if (ch == 0) // 仅打印少许信息避免刷屏
                    $display("Input  @ Time %0t: Row=%0d, Col=%0d, Val_Ch0=%02d", $time, r, c, get_pixel_val(r,c,0));
                
                #10; // 等待一个时钟周期
            end
        end

        // --- 结束输入，继续运行时钟以观察剩余输出 ---
        i_valid = 0;
        i_data_parallel = 0;
        
        #200; // 等待足够的时间让流水线排空 (Padding Bottom需要时间)
        
        $display("-------------------------------------------------------------");
        $display("Simulation Done");
        $finish;
    end

    // =================================================================
    // 6. 输出监控 (Monitor)
    // =================================================================
    // 解析 Packed 数据以便打印
    reg [DATA_WIDTH-1:0] debug_window [NUM_CHANNELS-1:0][FILTER_SIZE-1:0][FILTER_SIZE-1:0];
    
    integer i, j, k;
    always @(*) begin
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
            for (j = 0; j < FILTER_SIZE; j = j + 1) begin
                for (k = 0; k < FILTER_SIZE; k = k + 1) begin
                    debug_window[i][j][k] = o_windows_packed[ (i*9 + j*3 + k)*DATA_WIDTH +: DATA_WIDTH ];
                end
            end
        end
    end

    // 只有当 valid 有效时才打印窗口内容
    always @(posedge clk) begin
        if (o_valid) begin
            $display(">> OUTPUT VALID @ Time %0t", $time);
            // 打印 Channel 0 的 3x3 窗口
            $display("   [Channel 0 Window]:");
            $display("   %2d %2d %2d", debug_window[0][0][0], debug_window[0][0][1], debug_window[0][0][2]);
            $display("   %2d %2d %2d", debug_window[0][1][0], debug_window[0][1][1], debug_window[0][1][2]);
            $display("   %2d %2d %2d", debug_window[0][2][0], debug_window[0][2][1], debug_window[0][2][2]);
            $display("");
        end
    end

endmodule

