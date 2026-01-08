//`timescale 1ns / 1ps

//module system_top(
//    input  wire        sys_clk,
//    input  wire        sys_rst_n,
    
//    // === 外部输入 (模拟 DMA) ===
//    input  wire        dma_valid,      // Valid
//    input  wire [63:0] dma_data,       // Data
//    output wire        dma_ready,      // Ready (反压输出给 DMA)
//   // ===  动态配置接口 (新增) === 
//    input  wire [15:0] cfg_width,    // 例如 224
//    input  wire [15:0] cfg_height,   // 例如 224
//    input  wire        cfg_pad_en,
//    // === 外部输出 (模拟 卷积核接口) ===
//    output wire        conv_valid,     
//    output wire [575:0] conv_window    // 3x3 * 8ch * 8bit
//);

//    // --- 内部握手信号 ---
//    wire [63:0] pp_data_out;    
//    wire        pp_valid_out;   
//    wire        padding_ready;  // 【关键】现在这个信号由 Padding 真正驱动

//    // ============================================================
//    // 1. 实例化 Ping-Pong Buffer (输入缓冲)
//    // ============================================================
//    pingpang u_pingpang (
//        .sys_clk            (sys_clk),
//        .sys_rst_n          (sys_rst_n),
        
//        // 上游接口 (DMA <-> PingPang)
//        .data_en            (dma_valid),
//        .data_in            (dma_data),
//        .o_upstream_ready   (dma_ready),
        
//        // 下游接口 (PingPang <-> Padding)
//        .i_downstream_ready (padding_ready), // 接收来自 Padding 的反压
//        .o_downstream_valid (pp_valid_out),
//        .data_out           (pp_data_out)
//    );

//    // ============================================================
//    // 2. 实例化 Padding Module (滑窗生成)
//    // ============================================================
//    // 假设你已经在 padding.v 中添加了 output wire o_ready
    
//    padding #(
//        .NUM_CHANNELS (8),
//        .DATA_WIDTH   (8),
//        .MAX_IMG_WIDTH(1024),
//        .FILTER_SIZE  (3)
//    ) u_padding (
//        .clk             (sys_clk),
//        .rst_n           (sys_rst_n),
//        // 输入流        
//        .i_cfg_width     (cfg_width),
//        .i_cfg_height    (cfg_height),
//        .i_cfg_pad_en    (cfg_pad_en     ),
//        .i_valid         (pp_valid_out),
//        .i_data_parallel (pp_data_out),
//        .o_ready         (padding_ready), // 【关键】连接反压输出
        
//        // 输出流
//        .o_valid         (conv_valid),
//        .o_windows_packed(conv_window)
//    );

//endmodule
`timescale 1ns / 1ps

module system_top(
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    
    // === 外部输入 (来自 FPGA Top / DMA) ===
    input  wire        dma_valid,      
    input  wire [63:0] dma_data,       
    input  wire        dma_last,       // (可选) 如果使用计数器版Padding，这个可以悬空
    output wire        dma_ready,      // 直接由 Padding 的 FIFO 驱动
    
    // === 动态配置接口 ===
    input  wire [15:0] cfg_width,
    input  wire [15:0] cfg_height,
    input  wire        cfg_pad_en,
    
    // === 外部输出 (给卷积核) ===
    output wire        conv_valid,     
    output wire [575:0] conv_window    // 3x3 * 8ch * 8bit
);

    // ============================================================
    // 1. Padding Module 直连
    // ============================================================
    // 注意：这里请确保你使用的是之前提供的【计数器版 Auto-Flush】padding.v
    // 因为去掉了 PingPong，Padding 必须自己负责处理数据流的末尾
    
    padding #(
        .NUM_CHANNELS (8),
        .DATA_WIDTH   (8),
        .MAX_IMG_WIDTH(1024),
        .FILTER_SIZE  (3)
    ) u_padding (
        .clk             (sys_clk),
        .rst_n           (sys_rst_n),
        
        // --- 核心修改：直接连接 DMA 信号 ---
        .i_valid         (dma_valid),      
        .i_data_parallel (dma_data),       
        .o_ready         (dma_ready),      // Padding 内部 FIFO 满时拉低 Ready
        
        // 动态配置
        .i_cfg_width     (cfg_width),
        .i_cfg_height    (cfg_height),
        .i_cfg_pad_en    (cfg_pad_en),
        
        // 下游反压 (假设卷积核始终 Ready，如果不是，请连接实际信号)
        .i_next_ready    (1'b1), 
        
        // 输出
        .o_valid         (conv_valid),
        .o_windows_packed(conv_window)
    );

endmodule
