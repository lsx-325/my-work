`timescale 1ns / 1ps

module line_buffer_with_padding #(
    parameter NUM_CHANNELS = 8,
    parameter DATA_WIDTH   = 8,
    parameter IMG_WIDTH    = 256,
    parameter IMG_HEIGHT   = 256,
    parameter FILTER_SIZE  = 3
)(
    input                                   clk,
    input                                   rst_n,
    input                                   i_valid,
    input [NUM_CHANNELS*DATA_WIDTH-1:0]     i_data_parallel,
    output reg                              o_valid,
    output [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] o_windows_packed
);

    localparam TOTAL_DATA_WIDTH = NUM_CHANNELS * DATA_WIDTH;

    // =========================================================================
    // 1. Line Buffers & 路径平衡 (Path Balancing)
    // =========================================================================
    // 目标：解决 BRAM 累积延迟导致的阶梯错位
    // 延迟分析：
    // LB Output Latency = Width + 1 (1 cycle BRAM read)
    // Row 0 (Input): Latency 0
    // Row 1 (LB0)  : Latency W + 1
    // Row 2 (LB1)  : Latency 2W + 2
    
    // 原始输出
    wire [TOTAL_DATA_WIDTH-1:0] lb0_out; // 原始 LB0 输出
    wire [TOTAL_DATA_WIDTH-1:0] lb1_out; // 原始 LB1 输出 (Top Row, 最慢)

    // 对齐后的行数据
    reg  [TOTAL_DATA_WIDTH-1:0] row_0_aligned; // Bot Row (需延迟 2 cycles)
    reg  [TOTAL_DATA_WIDTH-1:0] row_1_aligned; // Mid Row (需延迟 1 cycle)
    wire [TOTAL_DATA_WIDTH-1:0] row_2_aligned; // Top Row (基准，无需额外延迟)

    // 辅助寄存器用于打拍
    reg [TOTAL_DATA_WIDTH-1:0] row_0_d1; 

    // --- Line Buffer 实例化 ---
    dynamic_line_buffer #(.DATA_WIDTH(TOTAL_DATA_WIDTH), .MAX_DEPTH(IMG_WIDTH)) u_lb0 (
        .clk(clk), .i_valid(i_valid), .i_width(IMG_WIDTH[15:0]), 
        .i_data(i_data_parallel), .o_data(lb0_out)
    );

    dynamic_line_buffer #(.DATA_WIDTH(TOTAL_DATA_WIDTH), .MAX_DEPTH(IMG_WIDTH)) u_lb1 (
        .clk(clk), .i_valid(i_valid), .i_width(IMG_WIDTH[15:0]), 
        .i_data(lb0_out),         .o_data(lb1_out)
    );

    // --- 关键：硬件打拍对齐 ---
    always @(posedge clk) begin
        if (i_valid) begin
            // Row 0 (Bot): Input -> Delay 1 -> Delay 2
            row_0_d1      <= i_data_parallel;
            row_0_aligned <= row_0_d1;      // 延迟 2 拍，对齐 Top
            
            // Row 1 (Mid): LB0_Out -> Delay 1
            row_1_aligned <= lb0_out;       // 延迟 1 拍，对齐 Top
        end
    end
    
    // Row 2 (Top): 直接使用，因为它是最慢的 (延迟 2 拍来自 2个BRAM)
    assign row_2_aligned = lb1_out;

    // =========================================================================
    // 2. 移位寄存器 (Shift Register)
    // =========================================================================
    reg [DATA_WIDTH-1:0] window_raw [NUM_CHANNELS-1:0][FILTER_SIZE-1:0][FILTER_SIZE-1:0];
    integer c;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // reset
        end else if (i_valid) begin
            for (c = 0; c < NUM_CHANNELS; c = c + 1) begin
                // Row 0 (Top) <--- row_2_aligned (最旧的数据)
                window_raw[c][0][0] <= window_raw[c][0][1];
                window_raw[c][0][1] <= window_raw[c][0][2];
                window_raw[c][0][2] <= row_2_aligned[c*DATA_WIDTH +: DATA_WIDTH];
                
                // Row 1 (Mid) <--- row_1_aligned
                window_raw[c][1][0] <= window_raw[c][1][1];
                window_raw[c][1][1] <= window_raw[c][1][2];
                window_raw[c][1][2] <= row_1_aligned[c*DATA_WIDTH +: DATA_WIDTH];

                // Row 2 (Bot) <--- row_0_aligned (最新数据，已延迟对齐)
                window_raw[c][2][0] <= window_raw[c][2][1];
                window_raw[c][2][1] <= window_raw[c][2][2];
                window_raw[c][2][2] <= row_0_aligned[c*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    end

    // =========================================================================
    // 3. 坐标与 Valid 控制
    // =========================================================================
    reg [15:0] col_ptr;
    reg [15:0] row_ptr;
    
    // 由于数据整体滞后了 2 个周期 (对齐到了最慢的路径)，
    // 有效的中心点计算也需要相应匹配。
    // 但因为 col_ptr 也是随着 i_valid 更新的，它们是同步推进的。
    // 我们只需要保证 padding 逻辑引用的是"当前从 shift register 出来"的坐标即可。
    
    wire signed [16:0] center_x = col_ptr - 1;
    wire signed [16:0] center_y = row_ptr - 1;
    reg pad_top, pad_bottom, pad_left, pad_right;
    reg center_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_ptr <= 0; row_ptr <= 0;
            pad_top <= 0; pad_bottom <= 0; pad_left <= 0; pad_right <= 0;
            center_valid <= 0;
        end else if (i_valid) begin
            // 坐标更新
            if (col_ptr == IMG_WIDTH - 1) begin
                col_ptr <= 0;
                if (row_ptr == IMG_HEIGHT - 1) row_ptr <= 0;
                else row_ptr <= row_ptr + 1;
            end else begin
                col_ptr <= col_ptr + 1;
            end

            // Padding 标志
            pad_top    <= (center_y == 0);
            pad_bottom <= (center_y == IMG_HEIGHT - 1);
            pad_left   <= (center_x == 0);
            pad_right  <= (center_x == IMG_WIDTH - 1);

            // Valid 判定
            // 当数据延迟对齐后，我们需要等待 LineBuffer 填满。
            // 依然是等待第 1 行 (row_ptr=1) 开始输入时，才能产生有效窗口
            if (row_ptr == 0)
                center_valid <= 0;
            else
                center_valid <= 1;

        end else begin
            // 【重要】输入无效时，立即拉低 valid，防止死循环
            center_valid <= 0;
        end
    end
    
    // 输出 Valid 打一拍，匹配 Shift Register 的输出节奏
    always @(posedge clk) o_valid <= center_valid;

    // =========================================================================
    // 4. 打包输出
    // =========================================================================
    genvar gc, gr, gk;
    generate
        for (gc = 0; gc < NUM_CHANNELS; gc = gc + 1) begin : loop_ch
            for (gr = 0; gr < FILTER_SIZE; gr = gr + 1) begin : loop_row
                for (gk = 0; gk < FILTER_SIZE; gk = gk + 1) begin : loop_col
                    wire is_masked = (pad_top && (gr == 0)) || (pad_bottom && (gr == 2)) ||
                                     (pad_left && (gk == 0)) || (pad_right  && (gk == 2));
                    wire [DATA_WIDTH-1:0] raw = window_raw[gc][gr][gk];
                    assign o_windows_packed[(gc*9 + gr*3 + gk)*DATA_WIDTH +: DATA_WIDTH] = 
                           is_masked ? {DATA_WIDTH{1'b0}} : raw;
                end
            end
        end
    endgenerate

endmodule