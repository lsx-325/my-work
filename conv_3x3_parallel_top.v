`timescale 1ns / 1ps

module conv_3x3_parallel_top #(
    parameter NUM_CHANNELS = 8,   // 输入通道并行度 (例如 8, 16)
    parameter DATA_WIDTH   = 8,   // 原始数据位宽 (8-bit)
    parameter ACCUM_WIDTH  = 32,  // DSP 内部累加位宽
    parameter FILTER_SIZE  = 3    // 卷积核大小 (3x3)
)(
    input                                   clk,
    input                                   rst_n,
    input                                   i_valid, // 输入有效信号
    
    // =========================================================================
    // 1. 大规模并行输入接口
    // =========================================================================
    // 总位宽 = 通道数 * (3x3点数) * 8bit
    // 假设 8通道, 3x3: 输入总位宽 = 8 * 9 * 8 = 576 bit
    // 数据排列: [Ch7_Window, Ch6_Window, ... Ch0_Window]
    input [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] i_windows_packed,
    
    // 权重数据 (每个通道独立权重)
    input [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] i_kernels_A_packed,
    input [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] i_kernels_B_packed,

    // =========================================================================
    // 2. 最终输出接口
    // =========================================================================
    // 输出位宽自动扩展: 基础累加位宽 + log2(通道数)
    output signed [ACCUM_WIDTH+$clog2(NUM_CHANNELS)-1:0] o_final_sum_A,
    output signed [ACCUM_WIDTH+$clog2(NUM_CHANNELS)-1:0] o_final_sum_B,
    
    // 输出有效信号 (流水线完全打通后拉高)
    output                                               o_final_valid
);

    // 计算常量
    localparam NUM_POINTS = FILTER_SIZE * FILTER_SIZE; // 9
    localparam UNIT_BITS  = NUM_POINTS * DATA_WIDTH;   // 72 bits

    // 内部连接信号：收集所有 DSP 的输出
    wire [NUM_CHANNELS*ACCUM_WIDTH-1:0] packed_res_A;
    wire [NUM_CHANNELS*ACCUM_WIDTH-1:0] packed_res_B;
    wire [NUM_CHANNELS-1:0]             dsp_valid_bus;

    // =========================================================================
    // 3. 实例化 DSP 计算阵列 (Spatial Computation)
    // =========================================================================
    // 作用：并行计算 NUM_CHANNELS 个通道的 3x3 局部点积
    genvar i;
    generate
        for (i = 0; i < NUM_CHANNELS; i = i + 1) begin : gen_dsp_array
            
            // 信号切片：提取第 i 个通道的数据和权重
            wire [UNIT_BITS-1:0] w_slice   = i_windows_packed  [i*UNIT_BITS +: UNIT_BITS];
            wire [UNIT_BITS-1:0] k_a_slice = i_kernels_A_packed[i*UNIT_BITS +: UNIT_BITS];
            wire [UNIT_BITS-1:0] k_b_slice = i_kernels_B_packed[i*UNIT_BITS +: UNIT_BITS];

            dsp_slice_2x_output #(
                .ACCUM_WIDTH(ACCUM_WIDTH),
                .DATA_WIDTH (DATA_WIDTH),
                .FILTER_SIZE(FILTER_SIZE)
            ) u_dsp_slice (
                .clk              (clk),
                .rst_n            (rst_n),
                .i_valid          (i_valid),
                
                // 输入切片
                .i_window_packed  (w_slice),
                .i_kernel_A_packed(k_a_slice),
                .i_kernel_B_packed(k_b_slice),
                
                // 输出填入打包总线 (Bit Slicing 赋值)
                .o_sum_A          (packed_res_A[i*ACCUM_WIDTH +: ACCUM_WIDTH]),
                .o_sum_B          (packed_res_B[i*ACCUM_WIDTH +: ACCUM_WIDTH]),
                .o_valid_out      (dsp_valid_bus[i])
            );
        end
    endgenerate

    // =========================================================================
    // 4. 实例化加法树 A (Channel Aggregation - Sum A)
    // =========================================================================
    // 作用：将 NUM_CHANNELS 个 Sum_A 累加为一个总值
    pipelined_adder_tree #(
        .NUM_IN    (NUM_CHANNELS),
        .DATA_WIDTH(ACCUM_WIDTH)
    ) u_adder_tree_A (
        .clk          (clk),
        .rst_n        (rst_n),
        // 使用第0个DSP的valid作为触发信号 (所有DSP延迟一致)
        .i_valid      (dsp_valid_bus[0]), 
        .i_data_packed(packed_res_A), 
        
        .o_sum        (o_final_sum_A),
        .o_valid      (o_final_valid)
    );

    // =========================================================================
    // 5. 实例化加法树 B (Channel Aggregation - Sum B)
    // =========================================================================
    // 作用：将 NUM_CHANNELS 个 Sum_B 累加为一个总值
    pipelined_adder_tree #(
        .NUM_IN    (NUM_CHANNELS),
        .DATA_WIDTH(ACCUM_WIDTH)
    ) u_adder_tree_B (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_valid      (dsp_valid_bus[0]), 
        .i_data_packed(packed_res_B), 
        
        .o_sum        (o_final_sum_B),
        .o_valid      () // 不用接，共用 Tree A 的 valid
    );

endmodule