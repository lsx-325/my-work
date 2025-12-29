`timescale 1ns / 1ps

module dynamic_line_buffer #(
    parameter DATA_WIDTH = 8,
    parameter MAX_DEPTH  = 2048  // 支持的最大图像宽度
)(
    input                       clk,
    input                       rst_n,
    
    input                       i_valid,       // 写使能
    input  [15:0]               i_width,       // 【关键】当前图像宽度
    input  [DATA_WIDTH-1:0]     i_data,        // 输入数据
    output [DATA_WIDTH-1:0]     o_data         // 输出数据 (延迟了一行的像素)
);

    // --- 指针定义 ---
    // 使用比 log2(MAX_DEPTH) 多一位的位宽，方便处理指针回绕和计算
    reg [$clog2(MAX_DEPTH):0]   wr_ptr;
    wire [$clog2(MAX_DEPTH):0]  rd_ptr_calc;
    
    // 实际 RAM 地址
    wire [$clog2(MAX_DEPTH)-1:0] wr_addr;
    wire [$clog2(MAX_DEPTH)-1:0] rd_addr;

    // --- 1. 写指针逻辑 (简单的环形计数) ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else if (i_valid) begin
            if (wr_ptr == MAX_DEPTH - 1)
                wr_ptr <= 0;
            else
                wr_ptr <= wr_ptr + 1;
        end
    end

    // --- 2. 读地址计算 (核心修正：延迟补偿) ---
    // 原理：BRAM 读取数据需要 1 个时钟周期。
    // 如果我们想让输出数据 o_data 与当前输入 i_data 在逻辑上相差正好 i_width 个周期，
    // 我们必须"提前"一个位置读取，抵消 BRAM 的读延迟。
    // Read_Ptr = Write_Ptr - (Width - 1)
    
    wire [$clog2(MAX_DEPTH):0] latency_offset;
    assign latency_offset = i_width - 1; 

    // 处理环形缓冲区的减法回绕
    assign rd_ptr_calc = (wr_ptr >= latency_offset) ? 
                         (wr_ptr - latency_offset) : 
                         (wr_ptr + MAX_DEPTH - latency_offset);
    
    assign wr_addr = wr_ptr[$clog2(MAX_DEPTH)-1:0];
    assign rd_addr = rd_ptr_calc[$clog2(MAX_DEPTH)-1:0];

    // --- 3. 推断双端口 RAM (Inferred BRAM) ---
    reg [DATA_WIDTH-1:0] ram [0:MAX_DEPTH-1];
    reg [DATA_WIDTH-1:0] ram_out;

    always @(posedge clk) begin
        if (i_valid) begin
            ram[wr_addr] <= i_data;
        end
    end

    always @(posedge clk) begin
        // 只要时钟在跑，就持续读取上一行的数据
        // 如果需要更严格的功耗控制，可以将 i_valid 作为读使能
        ram_out <= ram[rd_addr]; 
    end

    assign o_data = ram_out;

endmodule