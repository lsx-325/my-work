`timescale 1ns / 1ps

module pingpang
(
    input  wire        sys_clk ,      // 系统时钟 50MHz
    input  wire        sys_rst_n ,    // 复位 (低有效)
    
    // ------------------------------------------
    // 上游接口 (接收数据)
    // ------------------------------------------
    input  wire        data_en ,      // 输入 Valid
    input  wire [63:0] data_in ,      // 输入 Data
    output wire        o_upstream_ready, // 【新增】输出 Ready (反压上游)

    // ------------------------------------------
    // 下游接口 (发送数据)
    // ------------------------------------------
    input  wire        i_downstream_ready, // 【新增】输入 Ready (接收反压)
    output wire        o_downstream_valid, // 【新增】输出 Valid
    output wire [63:0] data_out            // 输出 Data
);

    //================================================
    // Internal Signals
    //================================================
    wire clk_50m ;
    wire rst_n ;

    // RAM1 连接信号
    wire [63:0] ram1_rd_data ;
    wire [63:0] ram1_wr_data ;
    wire ram1_wr_en ;
    wire ram1_rd_en ;
    wire [5:0] ram1_wr_addr ;
    wire [5:0] ram1_rd_addr ;

    // RAM2 连接信号
    wire [63:0] ram2_rd_data ;
    wire [63:0] ram2_wr_data ;
    wire ram2_wr_en ;
    wire ram2_rd_en ;
    wire [5:0] ram2_wr_addr ;
    wire [5:0] ram2_rd_addr ;

    // 简单赋值
    assign rst_n   = sys_rst_n ;
    assign clk_50m = sys_clk ;

    //================================================
    // 1. 实例化控制核心 (ram_ctrl)
    //================================================
    ram_ctrl1 ram_ctrl_inst
    (
        .clk_50m      (clk_50m),
        .rst_n        (rst_n),
        
        // RAM 数据通路
        .ram1_rd_data (ram1_rd_data),
        .ram2_rd_data (ram2_rd_data),
        .ram1_wr_data (ram1_wr_data),
        .ram2_wr_data (ram2_wr_data),
        
        // RAM 控制信号
        .ram1_wr_en   (ram1_wr_en),
        .ram1_rd_en   (ram1_rd_en),
        .ram1_wr_addr (ram1_wr_addr),
        .ram1_rd_addr (ram1_rd_addr),
        
        .ram2_wr_en   (ram2_wr_en),
        .ram2_rd_en   (ram2_rd_en),
        .ram2_wr_addr (ram2_wr_addr),
        .ram2_rd_addr (ram2_rd_addr),

        // 上游握手
        .data_en          (data_en),
        .data_in          (data_in),
        .o_upstream_ready (o_upstream_ready), // 连接新增端口
        
        // 下游握手
        .i_downstream_ready (i_downstream_ready), // 连接新增端口
        .o_data_valid       (o_downstream_valid), // 连接新增端口
        .data_out           (data_out)
    );

    //================================================
    // 2. 实例化 RAM IP 核
    //================================================
    
    // RAM 1
    dist_mem_gen_0 sdp_ram1 (
        .clk (clk_50m),       // 【重要】修正时钟连接
        .we  (ram1_wr_en),
        .a   (ram1_wr_addr),
        .d   (ram1_wr_data),
        .dpra(ram1_rd_addr),
        .dpo (ram1_rd_data)
    );

    // RAM 2
    dist_mem_gen_0 sdp_ram2 (
        .clk (clk_50m),       // 【重要】修正时钟连接
        .we  (ram2_wr_en),
        .a   (ram2_wr_addr),
        .d   (ram2_wr_data),
        .dpra(ram2_rd_addr),
        .dpo (ram2_rd_data)
    );

endmodule