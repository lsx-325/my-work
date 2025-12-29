// `timescale 1ns / 1ps

// module padding #(
//     parameter NUM_CHANNELS = 8,    
//     parameter DATA_WIDTH   = 64,    
//     parameter IMG_WIDTH    = 512,    
//     parameter IMG_HEIGHT   = 512,    
//     parameter FILTER_SIZE  = 3     
// )(
//     input                                   clk,
//     input                                   rst_n,
//     input                                   i_cfg_pad_en, // 1=开启Padding(Same), 0=关闭(Valid)
//     input                                   i_valid,
//     input [NUM_CHANNELS*DATA_WIDTH-1:0]     i_data_parallel,

//     output reg                              o_valid,
//     output wire                             o_ready, // 【新增】告诉上游：我可以接收数据
//     output [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] o_windows_packed
// );

//     // 1. 参数计算
//     localparam PAD = FILTER_SIZE / 2; 
//     localparam TOTAL_WIDTH  = IMG_WIDTH + 2*PAD; 
//     localparam TOTAL_HEIGHT = IMG_HEIGHT + 2*PAD; 

//     // 2. FWFT FIFO
//     wire [NUM_CHANNELS*DATA_WIDTH-1:0] fifo_dout;
//     wire fifo_empty;
//     reg  fifo_rd_en;
//     wire fifo_full;
    
//     fwft_fifo_behavioral #(.DATA_WIDTH(NUM_CHANNELS*DATA_WIDTH), .DEPTH(512)) u_input_fifo (
//         .clk(clk), .rst_n(rst_n),
//         .wr_en(i_valid), .din(i_data_parallel),
//         .rd_en(fifo_rd_en), .dout(fifo_dout),
//         .empty(fifo_empty), .full(fifo_full)
//     );
//     assign o_ready = !fifo_full; // 输出给 Ping-Pong

//     // 3. 扫描状态机
//     reg [15:0] x_cnt, y_cnt; 
//     reg running; 
//     wire in_active_region = (x_cnt >= PAD) && (x_cnt < IMG_WIDTH + PAD) && (y_cnt >= PAD) && (y_cnt < IMG_HEIGHT + PAD);
//     wire can_advance = in_active_region ? (!fifo_empty) : 1'b1;

//     always @(*) fifo_rd_en = (in_active_region && !fifo_empty) ? 1'b1 : 1'b0;

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             x_cnt <= 0; y_cnt <= 0; running <= 0;
//         end else begin
//             if (!fifo_empty) running <= 1; 
//             if (running && can_advance) begin
//                 if (x_cnt == TOTAL_WIDTH - 1) begin
//                     x_cnt <= 0;
//                     if (y_cnt == TOTAL_HEIGHT - 1) begin y_cnt <= 0; running <= 0; end 
//                     else y_cnt <= y_cnt + 1;
//                 end else x_cnt <= x_cnt + 1;
//             end
//         end
//     end

//     // 4. 像素流 (二级流水线 d2，保证垂直对齐)
//     reg [NUM_CHANNELS*DATA_WIDTH-1:0] current_stream_pixel;
//     reg [NUM_CHANNELS*DATA_WIDTH-1:0] current_stream_pixel_d1; 
//     reg [NUM_CHANNELS*DATA_WIDTH-1:0] current_stream_pixel_d2; 
//     reg                               current_stream_valid;

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             current_stream_pixel <= 0; 
//             current_stream_pixel_d1 <= 0; 
//             current_stream_pixel_d2 <= 0;
//             current_stream_valid <= 0;
//         end else if (running && can_advance) begin
//             current_stream_valid <= 1;
//             // Stage 0
//             if (in_active_region) current_stream_pixel <= fifo_dout; else current_stream_pixel <= 0;
//             // Stage 1
//             current_stream_pixel_d1 <= (in_active_region) ? fifo_dout : 0;
//             // Stage 2 (Window Input)
//             current_stream_pixel_d2 <= current_stream_pixel_d1;
//         end else begin
//             current_stream_valid <= 0;
//         end
//     end

//     // 5. Line Buffers
//     reg [NUM_CHANNELS*DATA_WIDTH-1:0] lb0 [0:TOTAL_WIDTH-1]; 
//     reg [NUM_CHANNELS*DATA_WIDTH-1:0] lb1 [0:TOTAL_WIDTH-1]; 
//     reg [NUM_CHANNELS*DATA_WIDTH-1:0] rdata_lb0, rdata_lb1;
//     reg [15:0] x_cnt_d1;
//     integer i;
//     initial begin for (i=0; i<TOTAL_WIDTH; i=i+1) begin lb0[i] = 0; lb1[i] = 0; end end

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             rdata_lb0 <= 0; rdata_lb1 <= 0; x_cnt_d1 <= 0;
//             for (i=0; i<TOTAL_WIDTH; i=i+1) begin lb0[i] <= 0; lb1[i] <= 0; end
//         end else if (running && can_advance) begin
//             x_cnt_d1 <= x_cnt;
//             rdata_lb0 <= lb0[x_cnt]; rdata_lb1 <= lb1[x_cnt];
//             lb0[x_cnt] <= current_stream_pixel; lb1[x_cnt_d1] <= rdata_lb0; 
//         end
//     end

//     // 6. 滑窗 & 最终 Valid 修正
//     reg [NUM_CHANNELS*DATA_WIDTH-1:0] win [0:2][0:2]; 
//     integer r, c;
    
//     reg ramp_up_done;
//     always @(posedge clk or negedge rst_n) begin
//         if(!rst_n) ramp_up_done <= 0;
//         else if (y_cnt == 2) ramp_up_done <= 1; 
//         else if (!running) ramp_up_done <= 0;
//     end

//     // === 修正后的 Valid 判定 (向左回退 1 格) ===
    
//     // Phase A: 扫描行的前半段 (x=4, 5) -> 对应 Pixel 1, 2
//     wire phase_a_x = (x_cnt == 4 || x_cnt == 5);
//     wire phase_a_y = (y_cnt >= 2 && y_cnt <= 5);

//     // Phase B: 扫描行的后半段 (x=0, 1) -> 对应 Pixel 3, 4
//     // 注意：剔除了 x=2 (Right Pad)
//     wire phase_b_x = (x_cnt == 0 || x_cnt == 1);
//     wire phase_b_y = (y_cnt >= 3 || y_cnt == 0);

//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin
//             o_valid <= 0;
//             for(r=0; r<3; r=r+1) for(c=0; c<3; c=c+1) win[r][c] <= 0;
//         end else if (current_stream_valid) begin
//             for(r=0; r<3; r=r+1) for(c=0; c<2; c=c+1) win[r][c] <= win[r][c+1];
            
//             win[2][2] <= current_stream_pixel_d2; 
//             win[1][2] <= rdata_lb0; 
//             win[0][2] <= rdata_lb1;

//             if ( ramp_up_done && ( (phase_a_x && phase_a_y) || (phase_b_x && phase_b_y) ) ) 
//                 o_valid <= 1;
//             else
//                 o_valid <= 0;
//         end else begin
//             o_valid <= 0;
//         end
//     end

//     // 7. 打包 (不变)
//     genvar gr, gc;
//     generate
//         for (gr = 0; gr < 3; gr = gr + 1) begin : pack_row
//             for (gc = 0; gc < 3; gc = gc + 1) begin : pack_col
//                 assign o_windows_packed[((gr*3 + gc + 1)*NUM_CHANNELS*DATA_WIDTH)-1 -: NUM_CHANNELS*DATA_WIDTH] 
//                        = win[gr][gc];
//             end
//         end
//     endgenerate
// endmodule

// // FWFT FIFO Module (Same as before)
// module fwft_fifo_behavioral #(
//     parameter DATA_WIDTH = 64, 
//     parameter DEPTH = 512)(
//     input clk, rst_n, wr_en, 
//     input [DATA_WIDTH-1:0] din, 
//     input rd_en,
//     output [DATA_WIDTH-1:0] dout, 
//     output empty, 
//     output full
// );
//     reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
//     reg [15:0] wr_ptr = 0, rd_ptr = 0, count = 0;
//     assign empty = (count == 0); assign full  = (count == DEPTH);
//     assign dout = mem[rd_ptr];
//     always @(posedge clk or negedge rst_n) begin
//         if (!rst_n) begin wr_ptr<=0; rd_ptr<=0; count<=0; end
//         else begin
//             if (wr_en && !full) begin
//                 mem[wr_ptr] <= din; wr_ptr <= (wr_ptr==DEPTH-1)?0:wr_ptr+1;
//                 if (!rd_en) count <= count + 1;
//             end
//             if (rd_en && !empty) begin
//                 rd_ptr <= (rd_ptr==DEPTH-1)?0:rd_ptr+1;
//                 if (!wr_en) count <= count - 1;
//             end
//         end
//     end
// endmodule
`timescale 1ns / 1ps

module padding #(
    parameter NUM_CHANNELS = 8,    
    parameter DATA_WIDTH   = 8,    
    // 【硬件资源上限】必须 >= 实际最大处理宽度
    parameter MAX_IMG_WIDTH = 1024, 
    parameter FILTER_SIZE  = 3     
)(
    input                                   clk,
    input                                   rst_n,
    
    // === 动态配置接口 ===
    input [15:0]                            i_cfg_width ,  // 当前层宽 (e.g. 4, 224, 512)
    input [15:0]                            i_cfg_height, // 当前层高
    input                                   i_cfg_pad_en, // 1=开启Padding(Same), 0=关闭(Valid)
    
    // === 数据流接口 ===
    input                                   i_valid,
    input [NUM_CHANNELS*DATA_WIDTH-1:0]     i_data_parallel,
    output reg                              o_valid,
    output wire                             o_ready,      // 反压信号
    output [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] o_windows_packed
);

    // ============================================================
    // 1. 参数与安全计算
    // ============================================================
    localparam PAD = FILTER_SIZE / 2; 

    // 【安全保护】限制配置宽度不超过硬件上限，防止 BRAM 溢出
    wire [15:0] safe_cfg_width = (i_cfg_width > MAX_IMG_WIDTH) ? MAX_IMG_WIDTH : i_cfg_width;

    // 动态计算总尺寸 (Image + Padding)
    wire [15:0] total_width  = safe_cfg_width + 2*PAD; 
    wire [15:0] total_height = i_cfg_height + 2*PAD; 

    // ============================================================
    // 2. 输入缓冲 FIFO (FWFT)
    // ============================================================
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] fifo_dout;
    wire fifo_empty, fifo_full;
    reg  fifo_rd_en;

    fwft_fifo_behavioral #(.DATA_WIDTH(NUM_CHANNELS*DATA_WIDTH), .DEPTH(1024)) u_input_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(i_valid), .din(i_data_parallel),
        .rd_en(fifo_rd_en), .dout(fifo_dout),
        .empty(fifo_empty), .full(fifo_full)
    );
    // 输出反压信号
    assign o_ready = !fifo_full; 

    // ============================================================
    // 3. 输入扫描状态机
    // ============================================================
    reg [15:0] x_cnt, y_cnt; 
    reg running; 
    
    // 判断当前扫描点是否在"有效图像区域"内 (用于决定是从 FIFO 读数据还是补 0)
    wire in_active_region = (x_cnt >= PAD) && (x_cnt < safe_cfg_width + PAD) && 
                            (y_cnt >= PAD) && (y_cnt < i_cfg_height + PAD);
                            
    // 只要还在有效区域内，就需要 FIFO 有数据才能前进；否则(在Padding区)可以直接跑
    wire can_advance = in_active_region ? (!fifo_empty) : 1'b1;

    always @(*) fifo_rd_en = (in_active_region && !fifo_empty) ? 1'b1 : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 0; y_cnt <= 0; running <= 0;
        end else begin
            if (!fifo_empty) running <= 1; 
            if (running && can_advance) begin
                // 基于 Total Width 扫描
                if (x_cnt == total_width - 1) begin
                    x_cnt <= 0;
                    if (y_cnt == total_height - 1) begin y_cnt <= 0; running <= 0; end 
                    else y_cnt <= y_cnt + 1;
                end else x_cnt <= x_cnt + 1;
            end
        end
    end

    // ============================================================
    // 4. 行缓存 (Line Buffers)
    // ============================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] current_stream_pixel;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] current_stream_pixel_d2; 
    reg                               current_stream_valid;

    // BRAM 资源定义
    localparam LB_DEPTH = MAX_IMG_WIDTH + 2*PAD; 
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] lb0 [0:LB_DEPTH-1]; 
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] lb1 [0:LB_DEPTH-1]; 
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] rdata_lb0, rdata_lb1;

    always @(posedge clk) begin
        if (running && can_advance) begin
            // 1. 先读出当前位置的旧数据 (用于滑窗的中间行和顶行)
            rdata_lb0 <= lb0[x_cnt];
            rdata_lb1 <= lb1[x_cnt];
            
            // 2. 准备新数据 (来自 FIFO 或 Padding 0)
            if (in_active_region) current_stream_pixel <= fifo_dout; 
            else current_stream_pixel <= 0;

            // 3. 写入 Line Buffer (更新缓存)
            // LB0 存最新行，LB1 存次新行(即 rdata_lb0)
            lb0[x_cnt] <= (in_active_region) ? fifo_dout : 0; 
            // 注意：这里我们把上一拍存在 lb0 的数据(现在读出来是 rdata_lb0) 存入 lb1
            // 但由于时序逻辑，在同一拍使用 lb0[x_cnt] (阻塞前) 是最直接的移位方式
            lb1[x_cnt] <= lb0[x_cnt]; 
        end
    end

    // 对齐流水线延迟 (Input -> Window Bottom 需要匹配 RAM 读取延迟)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            current_stream_valid <= 0; 
            current_stream_pixel_d2 <= 0;
        end else if (running && can_advance) begin
            current_stream_valid <= 1;
            current_stream_pixel_d2 <= (in_active_region) ? fifo_dout : 0; 
        end else begin
            current_stream_valid <= 0;
        end
    end

    // ============================================================
    // 5. 滑动窗口构建 (3x3 Shift Register)
    // ============================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] win [0:2][0:2]; 
    integer r, c;
    reg ramp_up_done;
    
    // 预热逻辑：等待前两行填满，且第三行的前两个像素进入移位寄存器
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) ramp_up_done <= 0;
        else if (y_cnt == 2 && x_cnt == 2) ramp_up_done <= 1; 
        else if (!running) ramp_up_done <= 0;
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
             for(r=0; r<3; r=r+1) for(c=0; c<3; c=c+1) win[r][c] <= 0;
        end else if (current_stream_valid) begin
             // 左移操作
             for(r=0; r<3; r=r+1) for(c=0; c<2; c=c+1) win[r][c] <= win[r][c+1];
             // 新的一列进入
             win[2][2] <= current_stream_pixel_d2; // Bottom
             win[1][2] <= rdata_lb0;                 // Middle
             win[0][2] <= rdata_lb1;                 // Top
        end
    end

    // ============================================================
    // 6. [修正版] 输出坐标追踪与 Valid 判定
    // ============================================================
    reg [15:0] out_x, out_y;

    // 6.1 坐标计数器
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            out_x <= 0; out_y <= 0; 
        end else if (current_stream_valid && ramp_up_done) begin
            // 基于 Total Width 循环计数
            if (out_x == total_width - 1) begin
                out_x <= 0;
                if (out_y == total_height - 1) out_y <= 0;
                else out_y <= out_y + 1;
            end else begin
                out_x <= out_x + 1;
            end
        end else if (!running) begin
             out_x <= 0; out_y <= 0;
        end
    end

    // 6.2 边缘与有效性判定 (改为组合逻辑 Wire，消除1拍延迟，解决Center=1丢失问题)
    
    // 判断当前列是否属于有效图像区域 (0 ~ width-1)
    wire is_active_col = (out_x < safe_cfg_width); 
    
    // 边缘判定
    wire is_border_left   = (out_x == 0);
    wire is_border_right  = (out_x == safe_cfg_width - 1);
    wire is_border_top    = (out_y == 0);
    wire is_border_bottom = (out_y == i_cfg_height - 1);
    wire is_border = is_border_left || is_border_right || is_border_top || is_border_bottom;

    // 6.3 最终输出 Valid 控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 0;
        end else if (current_stream_valid && ramp_up_done) begin
            // 只有当当前列是有效图像数据时，才考虑输出 Valid
            // (过滤掉行尾为了补齐 Padding 而产生的气泡周期)
            if (is_active_col) begin
                if (i_cfg_pad_en) begin
                    // 【开启 Padding】: 输出所有有效列，包括边缘
                    o_valid <= 1'b1;
                end else begin
                    // 【关闭 Padding】: 如果是边缘则屏蔽
                    if (is_border) 
                        o_valid <= 1'b0;
                    else 
                        o_valid <= 1'b1;
                end
            end else begin
                o_valid <= 1'b0;
            end
        end else begin
            o_valid <= 0;
        end
    end

    // ============================================================
    // 7. 打包输出
    // ============================================================
    genvar gr, gc;
    generate
        for (gr = 0; gr < 3; gr = gr + 1) begin : pack_row
            for (gc = 0; gc < 3; gc = gc + 1) begin : pack_col
                assign o_windows_packed[((gr*3 + gc + 1)*NUM_CHANNELS*DATA_WIDTH)-1 -: NUM_CHANNELS*DATA_WIDTH] 
                       = win[gr][gc];
            end
        end
    endgenerate

endmodule

// ============================================================
// 附：FWFT FIFO 模块 (必须包含)
// ============================================================
module fwft_fifo_behavioral #(
    parameter DATA_WIDTH = 64, 
    parameter DEPTH = 512)(
    input clk, rst_n, wr_en, 
    input [DATA_WIDTH-1:0] din, 
    input rd_en,
    output [DATA_WIDTH-1:0] dout, 
    output empty, 
    output full
);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [15:0] wr_ptr = 0, rd_ptr = 0, count = 0;
    
    assign empty = (count == 0); 
    assign full  = (count == DEPTH);
    assign dout = mem[rd_ptr]; // FWFT 特性：数据直接输出
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wr_ptr<=0; rd_ptr<=0; count<=0; end
        else begin
            if (wr_en && !full) begin
                mem[wr_ptr] <= din; 
                wr_ptr <= (wr_ptr==DEPTH-1)?0:wr_ptr+1;
                if (!rd_en) count <= count + 1;
            end
            if (rd_en && !empty) begin
                rd_ptr <= (rd_ptr==DEPTH-1)?0:rd_ptr+1;
                if (!wr_en) count <= count - 1;
            end
        end
    end
endmodule