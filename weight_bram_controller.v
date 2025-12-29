`timescale 1ns / 1ps

module weight_bram_controller #(
    parameter AXIS_DATA_WIDTH = 64,      // DMA 接口位宽 (64 或 32)
    parameter NUM_CHANNELS    = 8,       // 输入通道并行度
    parameter DATA_WIDTH      = 8,       // 权重数据位宽
    parameter FILTER_SIZE     = 3,       // 卷积核大小
    // BRAM 深度：可以存储多少组(Pairs)输出通道的权重
    // 例如 512 代表可以存储 512 * 2 = 1024 个输出通道的权重
    parameter BRAM_DEPTH      = 512      
)(
    input                                   clk,
    input                                   rst_n,

    // =========================================================================
    // 1. 写接口：来自 AXI DMA 的串行数据流
    // =========================================================================
    input                                   s_axis_tvalid,
    output reg                              s_axis_tready,
    input      [AXIS_DATA_WIDTH-1:0]        s_axis_tdata,
    input                                   s_axis_tlast,
    
    // 写地址复位信号（例如开始新的一层加载时脉冲一下）
    input                                   i_write_addr_rst, 

    // =========================================================================
    // 2. 读接口：连接到 conv_3x3_parallel_top
    // =========================================================================
    // 读地址：由主控模块决定当前计算第几个(对)输出通道
    input      [$clog2(BRAM_DEPTH)-1:0]     i_read_addr, 
    // 读使能：通常在计算开始时拉高
    input                                   i_read_en,   
    
    // 输出给核心的超宽权重数据
    output reg [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] o_kernels_A_packed,
    output reg [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] o_kernels_B_packed
);

    // =========================================================================
    // 参数计算
    // =========================================================================
    // 单个 Kernel Set 的位宽 (例如 8*9*8 = 576 bits)
    localparam KERNEL_SET_WIDTH = NUM_CHANNELS * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH;
    // BRAM 的一行总位宽 (存 Kernel A + Kernel B) = 1152 bits
    localparam BRAM_LINE_WIDTH  = 2 * KERNEL_SET_WIDTH;
    
    // 计算填满一行 BRAM 需要多少个 AXI 传输周期
    // 例如 1152 / 64 = 18 次
    localparam BEATS_PER_LINE   = BRAM_LINE_WIDTH / AXIS_DATA_WIDTH;

    // =========================================================================
    // BRAM 定义 (使用 Vivado 综合属性强制使用 Block RAM)
    // =========================================================================
    (* ram_style = "block" *) 
    reg [BRAM_LINE_WIDTH-1:0] mem_array [0:BRAM_DEPTH-1];

    // =========================================================================
    // 写逻辑 (串转并 -> 写入 BRAM)
    // =========================================================================
    reg [BRAM_LINE_WIDTH-1:0] write_shift_reg; // 移位寄存器用于拼数据
    reg [15:0]                beat_cnt;        // 记录当前行接收了多少个64bit
    reg [$clog2(BRAM_DEPTH)-1:0] write_addr;   // 写地址指针

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axis_tready   <= 0;
            beat_cnt        <= 0;
            write_addr      <= 0;
            write_shift_reg <= 0;
        end else begin
            // 握手逻辑：默认时刻准备接收
            s_axis_tready <= 1'b1;

            // 地址复位逻辑
            if (i_write_addr_rst) begin
                write_addr <= 0;
                beat_cnt   <= 0;
            end

            // 数据接收逻辑
            if (s_axis_tvalid && s_axis_tready) begin
                // 1. 数据拼接到移位寄存器 (假设低位先发，填入低位)
                // 也可以设计为移位逻辑： write_shift_reg <= {s_axis_tdata, write_shift_reg[...]}
                // 这里采用索引填入方式，更加直观：
                write_shift_reg[beat_cnt*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] <= s_axis_tdata;

                // 2. 计数器管理
                if (beat_cnt == BEATS_PER_LINE - 1) begin
                    // 已拼满一行 -> 写入 BRAM
                    mem_array[write_addr] <= {s_axis_tdata, write_shift_reg[BRAM_LINE_WIDTH-AXIS_DATA_WIDTH-1 : 0]}; 
                    // 注意：上一行赋值是非阻塞的，为了保证时序，这里直接用组合逻辑拼最后一块数据写入内存
                    // 或者更稳妥的方式：在下一个周期写内存（会有气泡），或者使用如下逻辑：
                    
                    // 实际上，更标准的做法是：
                    // beat_cnt 加到最大值时，触发写使能，数据是完整的
                end
                
                if (beat_cnt == BEATS_PER_LINE - 1) begin
                    beat_cnt <= 0;
                    if (write_addr < BRAM_DEPTH - 1)
                        write_addr <= write_addr + 1;
                    else
                        write_addr <= 0; // 循环写或停下
                end else begin
                    beat_cnt <= beat_cnt + 1;
                end
            end
        end
    end

    // 修正的 BRAM 写操作 (同步写)
    // 为了时序收敛，我们通常在数据拼好后的下一拍写入
    // 上面的逻辑为了简化演示混合了拼数据和写数据，下面是更严谨的写法：
    reg mem_write_en;
    reg [BRAM_LINE_WIDTH-1:0] mem_write_data;
    
    always @(posedge clk) begin
        if (s_axis_tvalid && s_axis_tready && (beat_cnt == BEATS_PER_LINE - 1)) begin
            // 拼上最后一段数据，写入 RAM
            mem_array[write_addr] <= {s_axis_tdata, write_shift_reg[BRAM_LINE_WIDTH-AXIS_DATA_WIDTH-1 : 0]};
        end
    end

    // =========================================================================
    // 读逻辑 (从 BRAM 读出 -> 输出给 Core)
    // =========================================================================
    // BRAM 读通常有 1-2 个周期的延迟。这里实现 1 周期延迟输出。
    reg [BRAM_LINE_WIDTH-1:0] read_data_raw;

    always @(posedge clk) begin
        if (i_read_en) begin
            read_data_raw <= mem_array[i_read_addr];
        end
    end

    // 数据拆分：将读出的宽数据拆分为 Kernel A 和 Kernel B
    always @(*) begin
        // 低位给 A，高位给 B
        o_kernels_A_packed = read_data_raw[0                +: KERNEL_SET_WIDTH];
        o_kernels_B_packed = read_data_raw[KERNEL_SET_WIDTH +: KERNEL_SET_WIDTH];
    end

endmodule