`timescale 1ns / 1ps

module feature_map_saver_axis #(
    parameter AXIS_DATA_WIDTH = 64,      // DMA 接口位宽
    parameter INPUT_WIDTH     = 35,      // 卷积核输出位宽 (例如 32位累加 + log2(8通道) ≈ 35)
    parameter OUTPUT_WIDTH    = 8,       // 输出到DDR的位宽 (uint8)
    parameter QUANT_SHIFT     = 10       // 量化右移位数 (相当于除以 2^10)
)(
    input                               clk,
    input                               rst_n,

    // =========================================================================
    // 1. 来自 Conv Core 的输入接口
    // =========================================================================
    input                               i_valid,
    input        signed [INPUT_WIDTH-1:0] i_data_A, // Kernel A 的结果 (通道 N)
    input        signed [INPUT_WIDTH-1:0] i_data_B, // Kernel B 的结果 (通道 N+1)
    
    // =========================================================================
    // 2. 图像参数 (用于生成 TLAST)
    // =========================================================================
    // 图像总像素数 = Height * Width (空间像素数，不乘通道)
    // 模块会自动根据打包逻辑计算何时拉高 TLAST
    input        [31:0]                 i_total_pixels, 
    
    // =========================================================================
    // 3. AXI-Stream Master 输出 (连接 DMA S2MM)
    // =========================================================================
    output reg                          m_axis_tvalid,
    input                               m_axis_tready,
    output reg   [AXIS_DATA_WIDTH-1:0]  m_axis_tdata,
    output reg   [AXIS_DATA_WIDTH/8-1:0]m_axis_tkeep,
    output reg                          m_axis_tlast
);

    // =========================================================================
    // Stage 1: 后处理 (ReLU + Quantization + Clamp)
    // =========================================================================
    reg [OUTPUT_WIDTH-1:0] post_data_A;
    reg [OUTPUT_WIDTH-1:0] post_data_B;
    reg                    post_valid;

    // 量化处理函数
    function [OUTPUT_WIDTH-1:0] process_pixel;
        input signed [INPUT_WIDTH-1:0] raw_in;
        reg signed [INPUT_WIDTH-1:0] shifted;
        begin
            // 1. ReLU: 负数变0
            if (raw_in < 0) begin
                process_pixel = 0;
            end else begin
                // 2. Scaling: 右移量化 (相当于除以 2^QUANT_SHIFT)
                shifted = raw_in >>> QUANT_SHIFT;
                
                // 3. Clamping: 饱和截断到 8-bit (0~255)
                // 检查是否超过最大值 (2^8 - 1 = 255)
                if (shifted > { {(INPUT_WIDTH-OUTPUT_WIDTH){1'b0}}, {(OUTPUT_WIDTH){1'b1}} }) 
                    process_pixel = {(OUTPUT_WIDTH){1'b1}}; // 255
                else
                    process_pixel = shifted[OUTPUT_WIDTH-1:0];
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_valid <= 0;
            post_data_A <= 0;
            post_data_B <= 0;
        end else begin
            post_valid <= i_valid;
            if (i_valid) begin
                post_data_A <= process_pixel(i_data_A);
                post_data_B <= process_pixel(i_data_B);
            end
        end
    end

    // =========================================================================
    // Stage 2: 数据打包 (Packing)
    // =========================================================================
    // 目标：将每次输入的 2 个 8-bit 数据拼凑成 64-bit 总线数据
    // 需要积累 4 次有效输入才能填满 64-bit (2 bytes * 4 = 8 bytes)
    
    reg [AXIS_DATA_WIDTH-1:0] pack_buffer; // 移位寄存器/缓存
    reg [1:0]                 pack_cnt;    // 计数器 0..3
    
    // TLAST 像素计数器
    reg [31:0]                pixel_counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tvalid <= 0;
            m_axis_tdata  <= 0;
            m_axis_tkeep  <= 8'hFF;
            m_axis_tlast  <= 0;
            pack_cnt      <= 0;
            pack_buffer   <= 0;
            pixel_counter <= 0;
        end else begin
            // 握手逻辑：如果从机Ready，则清除Valid，准备下一次传输
            if (m_axis_tready && m_axis_tvalid) begin
                m_axis_tvalid <= 0;
                m_axis_tlast  <= 0;
            end

            if (post_valid) begin
                // 填入 Buffer: 假设 Little-Endian (低地址放低位)
                // 每次填入 16 bits (Data B @ High, Data A @ Low)
                // pack_cnt=0: [15:0], pack_cnt=1: [31:16], ...
                pack_buffer[pack_cnt*16 +: 16] <= {post_data_B, post_data_A};
                
                // 更新像素计数 (每个 valid 时钟处理 1 个空间位置)
                if (pixel_counter < i_total_pixels - 1)
                    pixel_counter <= pixel_counter + 1;
                else
                    pixel_counter <= 0;

                // -------------------------------------------------------------
                // 发送条件判断
                // -------------------------------------------------------------
                // 1. Buffer 填满了 (pack_cnt == 3)
                // 2. 或者 已经是最后一个像素了 (需要强制发送剩余的不完整包)
                if (pack_cnt == 3 || pixel_counter == i_total_pixels - 1) begin
                    
                    m_axis_tvalid <= 1;
                    
                    // 将当前数据拼接到 buffer 高位并输出
                    // 注意：pack_buffer 中存储的是前 0~2 次的数据，当前第 3 次的数据直接组合输出
                    // 这里的位移逻辑确保数据顺序正确：D3_D2_D1_D0 (D0在低位)
                    // 如果是最后一次传输且 pack_cnt < 3，需要特殊处理数据对齐
                    
                    case (pack_cnt)
                        0: m_axis_tdata <= { {(64-16){1'b0}}, post_data_B, post_data_A };
                        1: m_axis_tdata <= { {(64-32){1'b0}}, post_data_B, post_data_A, pack_buffer[15:0] };
                        2: m_axis_tdata <= { {(64-48){1'b0}}, post_data_B, post_data_A, pack_buffer[31:0] };
                        3: m_axis_tdata <= { post_data_B, post_data_A, pack_buffer[47:0] };
                    endcase
                    
                    // 处理 TLAST 和 TKEEP
                    if (pixel_counter == i_total_pixels - 1) begin
                        m_axis_tlast <= 1;
                        // 计算有效字节 (Strobe)
                        // pack_cnt=0 -> 2 bytes, =1 -> 4 bytes, =2 -> 6 bytes, =3 -> 8 bytes
                        case(pack_cnt)
                            0: m_axis_tkeep <= 8'b0000_0011;
                            1: m_axis_tkeep <= 8'b0000_1111;
                            2: m_axis_tkeep <= 8'b0011_1111;
                            3: m_axis_tkeep <= 8'b1111_1111;
                        endcase
                        pack_cnt <= 0; // 帧结束复位
                    end else begin
                        m_axis_tlast <= 0;
                        m_axis_tkeep <= 8'hFF; // 中间数据全有效
                        pack_cnt <= 0;         // 填满复位
                    end
                end else begin
                    // 还没满且不是最后一个，继续攒
                    pack_cnt <= pack_cnt + 1;
                end
            end
        end
    end

endmodule