`timescale 1ns / 1ps

module axis_ping_pong_buffer #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 6,   // 2^6 = 64 depth
    parameter MAX_DEPTH  = 64
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // ========================================
    // AXI-Stream Slave (Input / Upstream)
    // ========================================
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    input  wire                   s_axis_tlast,
    output wire                   s_axis_tready,

    // ========================================
    // AXI-Stream Master (Output / Downstream)
    // ========================================
    output reg  [DATA_WIDTH-1:0]  m_axis_tdata,
    output reg                    m_axis_tvalid,
    output reg                    m_axis_tlast,
    input  wire                   m_axis_tready
);

    // =========================================================================
    // 1. 内存定义 (Distributed RAM 或 Block RAM 均兼容)
    // =========================================================================
    reg [DATA_WIDTH-1:0] ram_buf0 [0:MAX_DEPTH-1];
    reg [DATA_WIDTH-1:0] ram_buf1 [0:MAX_DEPTH-1];

    // 长度必须定义为 ADDR_WIDTH + 1 位，以能够存储数值 "64"
    reg [ADDR_WIDTH:0]   len_buf0, len_buf1; 

    // Buffer 状态: 0 = 空/正在写, 1 = 满/待读取
    reg [1:0] buf_full; 

    // =========================================================================
    // 2. 写入逻辑 (Write Control)
    // =========================================================================
    reg [ADDR_WIDTH:0] wr_ptr;      
    reg                wr_sel;      // 当前正在写的 buffer 索引 (0/1)
    
    // 只有当当前选中的 buffer 不满时，才向为了上游提供 Ready
    assign s_axis_tready = !buf_full[wr_sel];

    wire wr_handshake = s_axis_tvalid && s_axis_tready;
    wire wr_finish    = wr_handshake && (s_axis_tlast || (wr_ptr == MAX_DEPTH-1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr   <= 0;
            wr_sel   <= 0;
            buf_full <= 2'b00;
            len_buf0 <= 0;
            len_buf1 <= 0;
        end else begin
            // --- 状态清除 ---
            // 接收读取侧的脉冲信号，清除 Full 标志
            if (rd_buf_done_pulse) 
                buf_full[rd_sel_reg] <= 1'b0;

            // --- 写入主逻辑 ---
            if (wr_handshake) begin
                if (wr_sel == 0) ram_buf0[wr_ptr] <= s_axis_tdata;
                else             ram_buf1[wr_ptr] <= s_axis_tdata;

                if (wr_finish) begin
                    buf_full[wr_sel] <= 1'b1;         // 标记当前 Buffer 满
                    
                    // 记录长度
                    if (wr_sel == 0) len_buf0 <= wr_ptr + 1'b1;
                    else             len_buf1 <= wr_ptr + 1'b1;

                    // 切换
                    wr_sel <= ~wr_sel;
                    wr_ptr <= 0;
                end else begin
                    wr_ptr <= wr_ptr + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 3. 读取逻辑 (Read Control) - 修复了 Valid 时序问题
    // =========================================================================
    reg [ADDR_WIDTH:0] rd_ptr;
    reg                rd_sel;      // 当前正在读的 buffer 索引
    reg                rd_active;   // 状态标志：是否处于连续读取中

    // 跨模块交互信号
    reg  rd_buf_done_pulse; // 通知写入侧释放 Buffer
    reg  rd_sel_reg;        // 记录刚刚释放的是哪个 Buffer

    wire [ADDR_WIDTH:0] current_rd_len = (rd_sel == 0) ? len_buf0 : len_buf1;

    // 组合逻辑读取数据 (Distributed RAM 模式)
    reg [DATA_WIDTH-1:0] ram_rdata_comb;
    always @(*) begin
        if (rd_sel == 0) ram_rdata_comb = ram_buf0[rd_ptr];
        else             ram_rdata_comb = ram_buf1[rd_ptr];
    end

    // 读取使能条件：
    // 1. 正在运行 (rd_active) 且下游 Ready
    // 2. 没运行，但当前 Buffer 满了 (buf_full) 且没发过完成脉冲
    wire rd_enable = (rd_active) ? m_axis_tready : (buf_full[rd_sel] && !rd_buf_done_pulse);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr            <= 0;
            rd_sel            <= 0;
            rd_active         <= 0;
            rd_buf_done_pulse <= 0;
            rd_sel_reg        <= 0;
            m_axis_tvalid     <= 0;
            m_axis_tdata      <= 0;
            m_axis_tlast      <= 0;
        end else begin
            // 脉冲信号默认拉低
            rd_buf_done_pulse <= 0;

            if (rd_enable) begin
                // --- 第一级流水：地址控制 ---
                if (!rd_active) begin
                    // IDLE -> START: 启动读取
                    rd_active <= 1'b1;
                    rd_ptr    <= 1; // 预取下一个地址
                end else begin
                    // RUNNING: 地址递增或结束判断
                    if (rd_ptr == current_rd_len) begin
                        // 读完当前包
                        rd_active         <= 1'b0;
                        rd_ptr            <= 0;
                        rd_sel            <= ~rd_sel; // 切换读指针
                        rd_buf_done_pulse <= 1'b1;    // 发送释放脉冲
                        rd_sel_reg        <= rd_sel;
                    end else begin
                        rd_ptr <= rd_ptr + 1'b1;
                    end
                end

                // --- 第二级流水：输出数据打拍 ---
                // 只要处于 Active 状态或刚启动，就输出数据
                if (rd_active || (buf_full[rd_sel] && !rd_buf_done_pulse)) begin
                    m_axis_tdata  <= ram_rdata_comb;
                    m_axis_tvalid <= 1'b1; // 默认拉高，后面根据结束条件修正

                    // Last 信号判断：当前指针是 长度-1 (注意时序对齐)
                    if (rd_active && (rd_ptr == current_rd_len - 1'b1)) 
                        m_axis_tlast <= 1'b1;
                    else if (!rd_active && (current_rd_len == 1)) 
                        m_axis_tlast <= 1'b1; // 特殊情况：长度为1
                    else 
                        m_axis_tlast <= 1'b0;

                    // 【修复核心】：处理 Last 之后多余的 Valid
                    // 当 rd_ptr 到达 current_rd_len 时，表示当前包的最后一个数据已经在上一拍送出
                    // 这一拍是用来处理状态切换的
                    if (rd_ptr == current_rd_len) begin
                        // 如果下一个 Buffer (buf_full[~rd_sel]) 已经准备好，则保持 Valid 为 1 (无缝切换)
                        // 否则拉低 Valid，避免输出无效数据
                        if (buf_full[~rd_sel]) 
                            m_axis_tvalid <= 1'b1; 
                        else 
                            m_axis_tvalid <= 1'b0; 
                    end
                end
            end else if (m_axis_tready) begin
                // 如果下游 Ready 但我们没有数据 (rd_enable=0)，拉低 Valid
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
            end
        end
    end

endmodule