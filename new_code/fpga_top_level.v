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
        .cfg_width      (IMG_WIDTH),
        .cfg_height     (IMG_HEIGHT),
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
    // 4. Layer 2: 输入缓冲系统 (只有Padding)
    // =========================================================================
    // Layer 1 的输出结果 (8通道, 64bit) 进入 Layer 2 的padding
    
//    system_top u_sys_top_l2 (
//        .sys_clk        (clk),
//        .sys_rst_n      (rst_n),
        
//        // 连接来自 Layer 1 的数据
//        .dma_valid      (r_layer1_valid),
//        .dma_data       (r_layer1_out_packed),
//        .dma_ready      (w_l2_ready), // 这里的 Ready 可以用来做监控，或者如果需要更复杂的控制
//                                      // 正常情况下应反馈给 Layer 1 暂停流水线
                                      
//        // 动态配置 (Layer 2 尺寸与 Layer 1 相同)
//        .cfg_width      (IMG_WIDTH[15:0]),
//        .cfg_height     (IMG_HEIGHT[15:0]),
//        .cfg_pad_en     (1'b1), // Layer 2 同样开启 Padding
        
//        // 输出给 Layer 2 卷积核
//        .conv_valid     (w_win_valid_2),
//        .conv_window    (w_win_2)
//    );
    
    padding #(
        .NUM_CHANNELS (8),
        .DATA_WIDTH   (8),
        .MAX_IMG_WIDTH(1024),
        .FILTER_SIZE  (3)
    ) u_padding2 (
        .clk             (clk),
        .rst_n           (rst_n),
        // 输入流        
        .i_cfg_width     (IMG_WIDTH),
        .i_cfg_height    (IMG_HEIGHT),
        .i_cfg_pad_en    (1     ),
        .i_valid         (r_layer1_valid),
        .i_data_parallel (r_layer1_out_packed),
        .i_next_ready    (1'b1),
        .o_ready         (w_l2_ready), // 【关键】连接反压输出
        
        // 输出流
        .o_valid         (w_win_valid_2),
        .o_windows_packed(w_win_2)
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