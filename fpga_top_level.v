// `timescale 1ns / 1ps

// module fpga_top_level #(
//     parameter AXIS_DATA_WIDTH = 64,      // AXI Stream 位宽
//     parameter NUM_IN_CHANNELS = 8,       // 输入通道并行度
//     parameter DATA_WIDTH      = 8,       // 像素/权重位宽
//     parameter ACCUM_WIDTH     = 32,      // 累加位宽
//     parameter FILTER_SIZE     = 3,       // 3x3 卷积
//     parameter IMG_WIDTH       = 256,     // 图像宽度
//     parameter IMG_HEIGHT      = 256,     // 图像高度
//     parameter BRAM_DEPTH      = 512      // 权重 BRAM 深度
// )(
//     input                                   clk,
//     input                                   rst_n,

//     // 1. 图像输入 (AXI-Stream)
//     input                                   s_axis_img_tvalid,
//     output                                  s_axis_img_tready,
//     input      [AXIS_DATA_WIDTH-1:0]        s_axis_img_tdata,
//     input                                   s_axis_img_tlast,

//     // 2. 权重输入 (AXI-Stream) - 广播给所有 BRAM
//     input                                   s_axis_w_tvalid,
//     output reg                              s_axis_w_tready,
//     input      [AXIS_DATA_WIDTH-1:0]        s_axis_w_tdata,
//     input                                   s_axis_w_tlast,

//     // 3. 结果输出 (AXI-Stream)
//     output                                  m_axis_res_tvalid,
//     input                                   m_axis_res_tready,
//     output     [AXIS_DATA_WIDTH-1:0]        m_axis_res_tdata,
//     output     [AXIS_DATA_WIDTH/8-1:0]      m_axis_res_tkeep,
//     output                                  m_axis_res_tlast,

//     // 4. 控制与配置
//     input                                   i_load_weights,     // 权重加载使能
//     input      [3:0]                        i_target_layer,     // 权重加载目标层/块ID (用于片选BRAM)
    
//     input                                   i_start_compute,    // 开始计算
    
//     // **动态权重地址控制**
//     // 允许 PS 端指定当前计算使用哪一组权重 (实现类似 Batch 处理或多组滤波器切换)
//     input      [8:0]                        i_l1_weight_base,   // Layer 1 权重基地址
//     input      [8:0]                        i_l2_weight_base,   // Layer 2 权重基地址
    
//     output                                  o_compute_done
// );

//     // =========================================================================
//     // 参数计算
//     // =========================================================================
//     // Layer 1 需要输出 8 个通道，每个 Core 出 2 个，所以需要 4 个 Core
//     localparam L1_NUM_CORES = 4; 
    
//     // 基础位宽定义
//     localparam WIN_BITS = NUM_IN_CHANNELS * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH;
//     localparam W_BITS   = WIN_BITS; // 权重位宽与窗口位宽一致
//     localparam SUM_BITS = ACCUM_WIDTH + $clog2(NUM_IN_CHANNELS); // 35 bit

//     // =========================================================================
//     // 内部信号
//     // =========================================================================
    
//     // --- Layer 1 ---
//     wire w_win_valid_1;
//     wire [WIN_BITS-1:0] w_win_1;
    
//     // Layer 1 并行核心信号数组
//     wire [W_BITS-1:0]   w_ka_1 [L1_NUM_CORES-1:0];
//     wire [W_BITS-1:0]   w_kb_1 [L1_NUM_CORES-1:0];
//     wire signed [SUM_BITS-1:0] w_sum_a_1 [L1_NUM_CORES-1:0];
//     wire signed [SUM_BITS-1:0] w_sum_b_1 [L1_NUM_CORES-1:0];
//     wire [L1_NUM_CORES-1:0]    w_valid_1;

//     // 量化后的数据 (8 channels * 8 bit = 64 bit)
//     reg  [L1_NUM_CORES*2*DATA_WIDTH-1:0] r_layer1_out_packed; 
//     reg  r_layer1_valid;

//     // --- Layer 2 ---
//     wire w_win_valid_2;
//     wire [WIN_BITS-1:0] w_win_2; // Layer 2 输入也是 8 通道 (由 L1 输出拼接)
    
//     wire [W_BITS-1:0]   w_ka_2, w_kb_2;
//     wire signed [SUM_BITS-1:0] w_sum_a_2, w_sum_b_2;
//     wire w_valid_2;

//     // --- 权重握手 ---
//     // 简单逻辑：所有 BRAM 同时接收数据，通过写使能(地址复位)区分
//     // 这里简化为：始终 Ready，依靠 Valid 和 i_target_layer 区分
//     always @(*) s_axis_w_tready = 1'b1;

//     // =========================================================================
//     // 1. Layer 1: Line Buffer (Padding & Window Gen)
//     // =========================================================================
//     line_buffer_with_padding #(
//         .NUM_CHANNELS(NUM_IN_CHANNELS),
//         .DATA_WIDTH  (DATA_WIDTH),
//         .IMG_WIDTH   (IMG_WIDTH),
//         .IMG_HEIGHT  (IMG_HEIGHT)
//     ) u_lb_1 (
//         .clk             (clk),
//         .rst_n           (rst_n),
//         .i_valid         (s_axis_img_tvalid && s_axis_img_tready),
//         .i_data_parallel (s_axis_img_tdata),
//         .o_valid         (w_win_valid_1),
//         .o_windows_packed(w_win_1)
//     );
//     assign s_axis_img_tready = 1'b1; 

//     // =========================================================================
//     // 2. Layer 1: 并行计算阵列 (4 Cores -> 8 Output Channels)
//     // =========================================================================
//     genvar i;
//     generate
//         for (i = 0; i < L1_NUM_CORES; i = i + 1) begin : gen_l1_cores
            
//             // 2.1 权重 BRAM 控制器 (Bank i)
//             // 每个 Core 拥有独立的 BRAM，或者说是 BRAM 的一个逻辑分区
//             // 地址逻辑：Core[i] 读取 Base + i
//             weight_bram_controller #(
//                 .BRAM_DEPTH(BRAM_DEPTH)
//             ) u_w_bram_1 (
//                 .clk(clk), .rst_n(rst_n),
//                 // 写端口：所有 BRAM 并联到总线
//                 .s_axis_tvalid(s_axis_w_tvalid), 
//                 .s_axis_tready(), // 不驱动 Ready，防止多驱动冲突，顶层统一驱动
//                 .s_axis_tdata (s_axis_w_tdata),
//                 .s_axis_tlast (s_axis_w_tlast),
                
//                 // 写控制：仅当 target_layer == i 时才复位写地址并开始接收
//                 // 这样可以实现分时加载：先发 Core0权重，再发 Core1权重...
//                 .i_write_addr_rst(i_load_weights && (i_target_layer == i)),
                
//                 // 读控制：动态地址 + 偏移
//                 .i_read_addr(i_l1_weight_base), 
//                 .i_read_en  (1'b1),
                
//                 .o_kernels_A_packed(w_ka_1[i]),
//                 .o_kernels_B_packed(w_kb_1[i])
//             );

//             // 2.2 卷积核心
//             conv_3x3_parallel_top u_conv_1 (
//                 .clk(clk), .rst_n(rst_n),
//                 .i_valid(w_win_valid_1 && i_start_compute),
//                 .i_windows_packed(w_win_1), // 所有 Core 共享相同的输入窗口
//                 .i_kernels_A_packed(w_ka_1[i]),
//                 .i_kernels_B_packed(w_kb_1[i]),
//                 .o_final_sum_A(w_sum_a_1[i]),
//                 .o_final_sum_B(w_sum_b_1[i]),
//                 .o_final_valid(w_valid_1[i])
//             );
//         end
//     endgenerate

//     // =========================================================================
//     // 3. Layer 1 -> Layer 2 连接桥 (ReLU + Quantization + Concatenation)
//     // =========================================================================
//     // 量化函数
//     function [7:0] quantize;
//         input signed [34:0] val;
//         begin
//             if (val < 0) quantize = 0; // ReLU
//             else if ((val >>> 10) > 255) quantize = 255; // Clip
//             else quantize = val[17:10]; // Scale
//         end
//     endfunction

//     integer j;
//     always @(posedge clk or negedge rst_n) begin
//         if(!rst_n) begin
//             r_layer1_out_packed <= 0;
//             r_layer1_valid <= 0;
//         end else begin
//             // 使用 Core 0 的 valid 作为同步信号 (假设所有 Core 同步)
//             r_layer1_valid <= w_valid_1[0];
            
//             if (w_valid_1[0]) begin
//                 // 拼接 4 个 Core 的输出 (4 * 2 = 8 Channels)
//                 // Core 0 (Ch 0,1), Core 1 (Ch 2,3), Core 2 (Ch 4,5), Core 3 (Ch 6,7)
//                 // 假设 Little-Endian: {Core3_B, Core3_A ... Core0_B, Core0_A}
//                 for (j = 0; j < L1_NUM_CORES; j = j + 1) begin
//                     r_layer1_out_packed[(j*16) +: 8]      <= quantize(w_sum_a_1[j]); // Ch A
//                     r_layer1_out_packed[(j*16 + 8) +: 8]  <= quantize(w_sum_b_1[j]); // Ch B
//                 end
//             end
//         end
//     end

//     // =========================================================================
//     // 4. Layer 2: Line Buffer
//     // =========================================================================
//     // 此时 Layer 2 接收的是真实的 8 通道并行数据
//     line_buffer_with_padding #(
//         .NUM_CHANNELS(NUM_IN_CHANNELS), // 8
//         .IMG_WIDTH   (IMG_WIDTH),
//         .IMG_HEIGHT  (IMG_HEIGHT)
//     ) u_lb_2 (
//         .clk(clk), .rst_n(rst_n),
//         .i_valid(r_layer1_valid),
//         .i_data_parallel(r_layer1_out_packed),
//         .o_valid(w_win_valid_2),
//         .o_windows_packed(w_win_2)
//     );

//     // =========================================================================
//     // 5. Layer 2: 卷积计算 (单核心示例)
//     // =========================================================================
//     // 假设 Layer 2 只需要输出 2 个通道到 Saver
//     // 如果 Layer 2 也需要更多通道，可以同样使用 generate 复制
    
//     weight_bram_controller #(
//         .BRAM_DEPTH(BRAM_DEPTH)
//     ) u_w_bram_2 (
//         .clk(clk), .rst_n(rst_n),
//         .s_axis_tvalid(s_axis_w_tvalid), 
//         .s_axis_tready(), 
//         .s_axis_tdata (s_axis_w_tdata),
//         .s_axis_tlast (s_axis_w_tlast),
//         // Target ID 设为 4 (0-3 被 Layer 1 占用)
//         .i_write_addr_rst(i_load_weights && (i_target_layer == 4)), 
        
//         .i_read_addr(i_l2_weight_base), // 动态基地址
//         .i_read_en  (1'b1),
//         .o_kernels_A_packed(w_ka_2),
//         .o_kernels_B_packed(w_kb_2)
//     );

//     conv_3x3_parallel_top u_conv_2 (
//         .clk(clk), .rst_n(rst_n),
//         .i_valid(w_win_valid_2),
//         .i_windows_packed(w_win_2),
//         .i_kernels_A_packed(w_ka_2),
//         .i_kernels_B_packed(w_kb_2),
//         .o_final_sum_A(w_sum_a_2),
//         .o_final_sum_B(w_sum_b_2),
//         .o_final_valid(w_valid_2)
//     );

//     // =========================================================================
//     // 6. 结果输出
//     // =========================================================================
//     feature_map_saver_axis #(
//         .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
//         .INPUT_WIDTH    (ACCUM_WIDTH + $clog2(NUM_IN_CHANNELS)), 
//         .OUTPUT_WIDTH   (8),
//         .QUANT_SHIFT    (10)
//     ) u_saver (
//         .clk           (clk),
//         .rst_n         (rst_n),
//         .i_valid       (w_valid_2),
//         .i_data_A      (w_sum_a_2),
//         .i_data_B      (w_sum_b_2),
//         .i_total_pixels(IMG_WIDTH * IMG_HEIGHT),
        
//         .m_axis_tvalid (m_axis_res_tvalid),
//         .m_axis_tready (m_axis_res_tready),
//         .m_axis_tdata  (m_axis_res_tdata),
//         .m_axis_tkeep  (m_axis_res_tkeep),
//         .m_axis_tlast  (m_axis_res_tlast)
//     );
    
//     assign o_compute_done = m_axis_res_tvalid && m_axis_res_tlast;

// endmodule
`timescale 1ns / 1ps

module fpga_top_level #(
    parameter AXIS_DATA_WIDTH = 64,      // AXI Stream 位宽 (8通道 * 8bit)
    parameter NUM_IN_CHANNELS = 8,       // 输入通道并行度
    parameter DATA_WIDTH      = 8,       // 像素/权重位宽
    parameter ACCUM_WIDTH     = 32,      // 累加位宽
    parameter FILTER_SIZE     = 3,       // 3x3 卷积
    parameter IMG_WIDTH       = 256,     // 图像宽度
    parameter IMG_HEIGHT      = 256,     // 图像高度
    parameter BRAM_DEPTH      = 512      // 权重 BRAM 深度
)(
    input                                   clk,
    input                                   rst_n,

    // 1. 图像输入 (AXI-Stream)
    input                                   s_axis_img_tvalid,
    output                                  s_axis_img_tready, // 【修改】现在由 PingPong 驱动
    input      [AXIS_DATA_WIDTH-1:0]        s_axis_img_tdata,
    input                                   s_axis_img_tlast,

    // 2. 权重输入 (AXI-Stream) - 广播给所有 BRAM
    input                                   s_axis_w_tvalid,
    output                                  s_axis_w_tready,
    input      [AXIS_DATA_WIDTH-1:0]        s_axis_w_tdata,
    input                                   s_axis_w_tlast,

    // 3. 结果输出 (AXI-Stream)
    output                                  m_axis_res_tvalid,
    input                                   m_axis_res_tready,
    output     [AXIS_DATA_WIDTH-1:0]        m_axis_res_tdata,
    output     [AXIS_DATA_WIDTH/8-1:0]      m_axis_res_tkeep,
    output                                  m_axis_res_tlast,

    // 4. 控制与配置
    input                                   i_load_weights,     // 权重加载使能
    input      [3:0]                        i_target_layer,     // 权重加载目标层ID
    input                                   i_start_compute,    // 开始计算
    
    // **动态权重地址控制**
    input      [8:0]                        i_l1_weight_base,   
    input      [8:0]                        i_l2_weight_base, 
    
    output                                  o_compute_done
);

    // =========================================================================
    // 参数计算
    // =========================================================================
    localparam L1_NUM_CORES = 4;
    // 基础位宽定义
    localparam WIN_BITS = NUM_IN_CHANNELS * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH;
    localparam W_BITS   = WIN_BITS; 
    localparam SUM_BITS = ACCUM_WIDTH + $clog2(NUM_IN_CHANNELS);

    // =========================================================================
    // 内部信号
    // =========================================================================
    
    // --- Layer 1 ---
    wire w_win_valid_1;
    wire [WIN_BITS-1:0] w_win_1;
    
    wire [W_BITS-1:0]   w_ka_1 [L1_NUM_CORES-1:0];
    wire [W_BITS-1:0]   w_kb_1 [L1_NUM_CORES-1:0];
    wire signed [SUM_BITS-1:0] w_sum_a_1 [L1_NUM_CORES-1:0];
    wire signed [SUM_BITS-1:0] w_sum_b_1 [L1_NUM_CORES-1:0];
    wire [L1_NUM_CORES-1:0]    w_valid_1;

    // 量化后的数据
    reg  [L1_NUM_CORES*2*DATA_WIDTH-1:0] r_layer1_out_packed;
    reg  r_layer1_valid;

    // --- Layer 2 ---
    wire w_win_valid_2;
    wire [WIN_BITS-1:0] w_win_2;
    wire w_l2_ready; // Layer 2 的 PingPong 反压信号 (本例暂不处理 L1 暂停)
    
    wire [W_BITS-1:0]   w_ka_2, w_kb_2;
    wire signed [SUM_BITS-1:0] w_sum_a_2, w_sum_b_2;
    wire w_valid_2;

    // 权重 Ready 信号默认拉高
    assign s_axis_w_tready = 1'b1;

    // =========================================================================
    // 1. Layer 1: 输入缓冲系统 (PingPong + Padding + Window Gen)
    // =========================================================================
    // 【修改】替换原有的 line_buffer_with_padding
    
    system_top u_sys_top_l1 (
        .sys_clk        (clk),
        .sys_rst_n      (rst_n),
        
        // 外部 DMA / AXIS 输入
        .dma_valid      (s_axis_img_tvalid),
        .dma_data       (s_axis_img_tdata),
        .dma_ready      (s_axis_img_tready), // 输出反压信号给外部 AXI
        
        // 动态配置 (使用 Parameter 转换)
        .cfg_width      (IMG_WIDTH[15:0]),
        .cfg_height     (IMG_HEIGHT[15:0]),
        .cfg_pad_en     (1'b1), // Layer 1 开启 Padding (Same)
        
        // 输出给 Layer 1 卷积核
        .conv_valid     (w_win_valid_1),
        .conv_window    (w_win_1)
    );

    // =========================================================================
    // 2. Layer 1: 并行计算阵列 (4 Cores -> 8 Output Channels)
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < L1_NUM_CORES; i = i + 1) begin : gen_l1_cores
            
            // 2.1 权重 BRAM
            weight_bram_controller #(.BRAM_DEPTH(BRAM_DEPTH)) u_w_bram_1 (
                .clk(clk), .rst_n(rst_n),
                .s_axis_tvalid(s_axis_w_tvalid), 
                .s_axis_tready(), 
                .s_axis_tdata (s_axis_w_tdata),
                .s_axis_tlast (s_axis_w_tlast),
                .i_write_addr_rst(i_load_weights && (i_target_layer == i)),
                .i_read_addr(i_l1_weight_base), 
                .i_read_en  (1'b1),
                .o_kernels_A_packed(w_ka_1[i]),
                .o_kernels_B_packed(w_kb_1[i])
            );

            // 2.2 卷积核心
            // 注意：start_compute 控制有效性
            conv_3x3_parallel_top u_conv_1 (
                .clk(clk), .rst_n(rst_n),
                .i_valid(w_win_valid_1 && i_start_compute),
                .i_windows_packed(w_win_1), 
                .i_kernels_A_packed(w_ka_1[i]),
                .i_kernels_B_packed(w_kb_1[i]),
                .o_final_sum_A(w_sum_a_1[i]),
                .o_final_sum_B(w_sum_b_1[i]),
                .o_final_valid(w_valid_1[i])
            );
        end
    endgenerate

    // =========================================================================
    // 3. Layer 1 -> Layer 2 连接桥 (ReLU + Quantization)
    // =========================================================================
    function [7:0] quantize;
        input signed [34:0] val;
        begin
            if (val < 0) quantize = 0;                   // ReLU
            else if ((val >>> 10) > 255) quantize = 255; // Clip
            else quantize = val[17:10];                  // Scale
        end
    endfunction

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            r_layer1_out_packed <= 0;
            r_layer1_valid <= 0;
        end else begin
            // 简单逻辑：假设所有 Core 同步输出
            r_layer1_valid <= w_valid_1[0];
            
            if (w_valid_1[0]) begin
                for (j = 0; j < L1_NUM_CORES; j = j + 1) begin
                    r_layer1_out_packed[(j*16) +: 8]      <= quantize(w_sum_a_1[j]);
                    r_layer1_out_packed[(j*16 + 8) +: 8]  <= quantize(w_sum_b_1[j]);
                end
            end
        end
    end

    // =========================================================================
    // 4. Layer 2: 输入缓冲系统 (PingPong + Padding)
    // =========================================================================
    // 【修改】替换原有的 line_buffer_with_padding
    // Layer 1 的输出结果 (8通道, 64bit) 进入 Layer 2 的 Ping-Pong Buffer
    
    system_top u_sys_top_l2 (
        .sys_clk        (clk),
        .sys_rst_n      (rst_n),
        
        // 连接来自 Layer 1 的数据
        .dma_valid      (r_layer1_valid),
        .dma_data       (r_layer1_out_packed),
        .dma_ready      (w_l2_ready), // 这里的 Ready 可以用来做监控，或者如果需要更复杂的控制
                                      // 正常情况下应反馈给 Layer 1 暂停流水线
                                      
        // 动态配置 (Layer 2 尺寸与 Layer 1 相同)
        .cfg_width      (IMG_WIDTH[15:0]),
        .cfg_height     (IMG_HEIGHT[15:0]),
        .cfg_pad_en     (1'b1), // Layer 2 同样开启 Padding
        
        // 输出给 Layer 2 卷积核
        .conv_valid     (w_win_valid_2),
        .conv_window    (w_win_2)
    );

    // =========================================================================
    // 5. Layer 2: 卷积计算
    // =========================================================================
    weight_bram_controller #(.BRAM_DEPTH(BRAM_DEPTH)) u_w_bram_2 (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_w_tvalid), 
        .s_axis_tready(), 
        .s_axis_tdata (s_axis_w_tdata),
        .s_axis_tlast (s_axis_w_tlast),
        .i_write_addr_rst(i_load_weights && (i_target_layer == 4)), 
        .i_read_addr(i_l2_weight_base), 
        .i_read_en  (1'b1),
        .o_kernels_A_packed(w_ka_2),
        .o_kernels_B_packed(w_kb_2)
    );

    conv_3x3_parallel_top u_conv_2 (
        .clk(clk), .rst_n(rst_n),
        .i_valid(w_win_valid_2),
        .i_windows_packed(w_win_2),
        .i_kernels_A_packed(w_ka_2),
        .i_kernels_B_packed(w_kb_2),
        .o_final_sum_A(w_sum_a_2),
        .o_final_sum_B(w_sum_b_2),
        .o_final_valid(w_valid_2)
    );

    // =========================================================================
    // 6. 结果输出
    // =========================================================================
    feature_map_saver_axis #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .INPUT_WIDTH    (ACCUM_WIDTH + $clog2(NUM_IN_CHANNELS)), 
        .OUTPUT_WIDTH   (8),
        .QUANT_SHIFT    (10)
    ) u_saver (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_valid       (w_valid_2),
        .i_data_A      (w_sum_a_2),
        .i_data_B      (w_sum_b_2),
        .i_total_pixels(IMG_WIDTH * IMG_HEIGHT),
        .m_axis_tvalid (m_axis_res_tvalid),
        .m_axis_tready (m_axis_res_tready),
        .m_axis_tdata  (m_axis_res_tdata),
        .m_axis_tkeep  (m_axis_res_tkeep),
        .m_axis_tlast  (m_axis_res_tlast)
    );

    assign o_compute_done = m_axis_res_tvalid && m_axis_res_tlast;

endmodule