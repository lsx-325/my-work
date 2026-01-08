`timescale 1ns / 1ps

module padding #(
    parameter NUM_CHANNELS  = 8,
    parameter DATA_WIDTH    = 8,
    parameter MAX_IMG_WIDTH = 1024,
    parameter FILTER_SIZE   = 3
)(
    input  wire                                         clk,
    input  wire                                         rst_n,

    // === 动态配置接口 ===
    input  wire [15:0]                                  i_cfg_width,
    input  wire [15:0]                                  i_cfg_height,
    input  wire                                         i_cfg_pad_en,

    // === 数据流接口 ===
    input  wire                                         i_valid,
    input  wire [NUM_CHANNELS*DATA_WIDTH-1:0]           i_data_parallel,
    input  wire                                         i_tlast,      // 【新增】必须连接！
    output wire                                         o_ready,

    // 下游反压
    input  wire                                         i_next_ready, // 必须连接 system_top 传入的 conv_ready

    // 输出
    output reg                                          o_valid,
    output [NUM_CHANNELS*FILTER_SIZE*FILTER_SIZE*DATA_WIDTH-1:0] o_windows_packed
);

    // ============================================================
    // 1. 自动排空状态机 (Auto-Flush Control)
    // ============================================================
    // 当收到 TLAST 后，如果 FIFO 读空了，我们就进入 FLUSH 模式
    // 自己产生数据来填满最后需要的 Padding 行
    
    reg flush_active;
    reg flush_done_flag;
    reg [15:0] flush_pixel_cnt; // 计数 flush 了多少个点

    // 检测 TLAST 事件
    reg tlast_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tlast_seen <= 0;
        else if (i_valid && o_ready && i_tlast) tlast_seen <= 1; // 锁存 TLAST 事件
        else if (flush_done_flag) tlast_seen <= 0; // 完成后清除
    end

    // FIFO 信号定义
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] fifo_dout;
    wire fifo_empty, fifo_full;
    reg  fifo_rd_en;

    // ============================================================
    // 2. 虚拟数据源 (Virtual Data Source)
    // ============================================================
    // 如果处于 Flush 状态，我们伪造一个 "非空" 的 FIFO
    
    wire eff_fifo_empty; // 有效的空信号
    wire [NUM_CHANNELS*DATA_WIDTH-1:0] eff_fifo_dout;

    // 进入 Flush 的条件：看过了 TLAST，且真实 FIFO 已空
    wire start_flushing = tlast_seen && fifo_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_active <= 0;
            flush_pixel_cnt <= 0;
            flush_done_flag <= 0;
        end else begin
            flush_done_flag <= 0; // Pulse

            if (!flush_active) begin
                if (start_flushing) begin
                    flush_active <= 1;
                    flush_pixel_cnt <= 0;
                end
            end else begin
                // 在 Flush 模式下，只要下游肯吃，我们就计数
                // 我们需要补足最后一行(对于3x3 Same Padding) + 额外的流水线气泡
                // 简单起见，补 1 行完整的数据 (safe_cfg_width) + PAD
                if (i_next_ready) begin
                    if (flush_pixel_cnt >= i_cfg_width + 5) begin // +5 是余量，确保挤干净
                        flush_active <= 0;
                        flush_done_flag <= 1;
                    end else begin
                        flush_pixel_cnt <= flush_pixel_cnt + 1;
                    end
                end
            end
        end
    end

    // 【关键逻辑】欺骗状态机
    // 如果 Flush 激活，告诉状态机 "FIFO 不空" (eff_fifo_empty=0)
    assign eff_fifo_empty = fifo_empty && !flush_active;
    
    // 如果 Flush 激活，数据强制为 0
    assign eff_fifo_dout  = flush_active ? {NUM_CHANNELS*DATA_WIDTH{1'b0}} : fifo_dout;

    // ============================================================
    // 3. 原始 FIFO 实例化
    // ============================================================
    fwft_fifo_behavioral #(.DATA_WIDTH(NUM_CHANNELS*DATA_WIDTH), .DEPTH(1024)) u_input_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(i_valid), .din(i_data_parallel),
        .rd_en(fifo_rd_en), .dout(fifo_dout),
        .empty(fifo_empty), .full(fifo_full)
    );
    assign o_ready = !fifo_full; 

    // ============================================================
    // 4. 扫描状态机 (使用 eff_* 信号)
    // ============================================================
    localparam PAD = FILTER_SIZE / 2; 
    wire [15:0] safe_cfg_width = (i_cfg_width > MAX_IMG_WIDTH) ? MAX_IMG_WIDTH : i_cfg_width;
    wire [15:0] total_width  = safe_cfg_width + 2*PAD; 
    wire [15:0] total_height = i_cfg_height + 2*PAD; 

    reg [15:0] x_cnt, y_cnt; 
    reg running; 
    
    wire in_active_region = (x_cnt >= PAD) && (x_cnt < safe_cfg_width + PAD) && 
                            (y_cnt >= PAD) && (y_cnt < i_cfg_height + PAD);
                            
    // 这里的 fifo_empty 换成了 eff_fifo_empty
    wire can_advance = (in_active_region && i_next_ready) ? (!eff_fifo_empty) : i_next_ready;

    // FIFO 读控制：只有在非 Flush 状态下，才真的去读 FIFO
    always @(*) begin
        if (in_active_region && !fifo_empty && i_next_ready && !flush_active) 
            fifo_rd_en = 1'b1;
        else 
            fifo_rd_en = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 0; y_cnt <= 0; running <= 0;
        end else begin
            // 只要有效空信号为假 (即有真实数据 或 正在Flush)，就运行
            if (!eff_fifo_empty) running <= 1; 
            
            if (running && can_advance) begin
                if (x_cnt == total_width - 1) begin
                    x_cnt <= 0;
                    if (y_cnt == total_height - 1) begin y_cnt <= 0; running <= 0; end 
                    else y_cnt <= y_cnt + 1;
                end else x_cnt <= x_cnt + 1;
            end
        end
    end

    // ============================================================
    // 5. 行缓存 (Line Buffers)
    // ============================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] current_stream_pixel;
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] current_stream_pixel_d2; 
    reg                               current_stream_valid;

    localparam LB_DEPTH = MAX_IMG_WIDTH + 2*PAD; 
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] lb0 [0:LB_DEPTH-1]; 
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] lb1 [0:LB_DEPTH-1]; 
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] rdata_lb0, rdata_lb1;

    always @(posedge clk) begin
        if (running && can_advance) begin
            rdata_lb0 <= lb0[x_cnt];
            rdata_lb1 <= lb1[x_cnt];
            
            // 使用 eff_fifo_dout (可能是真实数据，也可能是 Flush 的 0)
            if (in_active_region) current_stream_pixel <= eff_fifo_dout; 
            else current_stream_pixel <= 0;

            lb0[x_cnt] <= (in_active_region) ? eff_fifo_dout : 0; 
            lb1[x_cnt] <= lb0[x_cnt]; 
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            current_stream_valid <= 0; 
            current_stream_pixel_d2 <= 0;
        end else if (running && can_advance) begin
            current_stream_valid <= 1;
            current_stream_pixel_d2 <= (in_active_region) ? eff_fifo_dout : 0; 
        end else begin
            current_stream_valid <= 0;
        end
    end

    // ============================================================
    // 6. 滑动窗口构建
    // ============================================================
    reg [NUM_CHANNELS*DATA_WIDTH-1:0] win [0:2][0:2]; 
    integer r, c;
    reg ramp_up_done;
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) ramp_up_done <= 0;
        else if (y_cnt == 2 && x_cnt == 2) ramp_up_done <= 1; 
        else if (!running) ramp_up_done <= 0;
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
             for(r=0; r<3; r=r+1) for(c=0; c<3; c=c+1) win[r][c] <= 0;
        end else if (current_stream_valid) begin
             for(r=0; r<3; r=r+1) for(c=0; c<2; c=c+1) win[r][c] <= win[r][c+1];
             win[2][2] <= current_stream_pixel_d2; 
             win[1][2] <= rdata_lb0;                 
             win[0][2] <= rdata_lb1;                 
        end
    end

    // ============================================================
    // 7. 输出坐标追踪与 Valid
    // ============================================================
    reg [15:0] out_x, out_y;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            out_x <= 0; out_y <= 0; 
        end else if (current_stream_valid && ramp_up_done) begin
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

    wire is_active_col = (out_x < safe_cfg_width); 
    wire is_border_left   = (out_x == 0);
    wire is_border_right  = (out_x == safe_cfg_width - 1);
    wire is_border_top    = (out_y == 0);
    wire is_border_bottom = (out_y == i_cfg_height - 1);
    wire is_border = is_border_left || is_border_right || is_border_top || is_border_bottom;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_valid <= 0;
        end else if (current_stream_valid && ramp_up_done) begin
            if (is_active_col) begin
                if (i_cfg_pad_en) begin
                    o_valid <= 1'b1;
                end else begin
                    if (is_border) o_valid <= 1'b0;
                    else o_valid <= 1'b1;
                end
            end else begin
                o_valid <= 1'b0;
            end
        end else begin
            o_valid <= 0;
        end
    end

    // 打包输出
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

// (保留 fwft_fifo_behavioral 模块不变)

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