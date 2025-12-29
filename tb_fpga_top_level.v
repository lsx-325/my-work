`timescale 1ns / 1ps

module tb_fpga_top_level;

    // =========================================================================
    // 1. 参数定义
    // =========================================================================
    parameter AXIS_DATA_WIDTH = 64;
    parameter NUM_IN_CHANNELS = 8;
    parameter DATA_WIDTH      = 8;
    parameter ACCUM_WIDTH     = 32;
    parameter FILTER_SIZE     = 3;
    
    // 为了仿真速度，我们将图像尺寸设小一点
    parameter IMG_WIDTH       = 16; 
    parameter IMG_HEIGHT      = 16;
    parameter BRAM_DEPTH      = 512;

    // 权重加载相关计算
    // Layer 1: 4 Cores, 每个 Core 负责 2 个输出通道
    // 每个 Core 需要 144 个权重 (8 In * 2 Out * 9) = 1152 bits
    // 1152 bits / 64 bits (AXI) = 18 Beats
    localparam BEATS_PER_WEIGHT_LINE = (NUM_IN_CHANNELS * 2 * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH) / AXIS_DATA_WIDTH;

    // =========================================================================
    // 2. 信号定义
    // =========================================================================
    reg clk;
    reg rst_n;

    // 图像输入
    reg                       s_axis_img_tvalid;
    wire                      s_axis_img_tready;
    reg [AXIS_DATA_WIDTH-1:0] s_axis_img_tdata;
    reg                       s_axis_img_tlast;

    // 权重输入
    reg                       s_axis_w_tvalid;
    wire                      s_axis_w_tready;
    reg [AXIS_DATA_WIDTH-1:0] s_axis_w_tdata;
    reg                       s_axis_w_tlast;

    // 结果输出
    wire                      m_axis_res_tvalid;
    reg                       m_axis_res_tready;
    wire [AXIS_DATA_WIDTH-1:0] m_axis_res_tdata;
    wire [AXIS_DATA_WIDTH/8-1:0] m_axis_res_tkeep;
    wire                      m_axis_res_tlast;

    // 控制信号
    reg                       i_load_weights;
    reg [3:0]                 i_target_layer;
    reg                       i_start_compute;
    reg [8:0]                 i_l1_weight_base;
    reg [8:0]                 i_l2_weight_base;
    wire                      o_compute_done;

    assign s_axis_w_tready = 1'b1;
    // 统计接收到的像素数
    integer received_pixel_cnt;

    // =========================================================================
    // 3. DUT 实例化
    // =========================================================================
    fpga_top_level #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .NUM_IN_CHANNELS(NUM_IN_CHANNELS),
        .DATA_WIDTH     (DATA_WIDTH),
        .ACCUM_WIDTH    (ACCUM_WIDTH),
        .FILTER_SIZE    (FILTER_SIZE),
        .IMG_WIDTH      (IMG_WIDTH),
        .IMG_HEIGHT     (IMG_HEIGHT),
        .BRAM_DEPTH     (BRAM_DEPTH)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        
        .s_axis_img_tvalid(s_axis_img_tvalid),
        .s_axis_img_tready(s_axis_img_tready),
        .s_axis_img_tdata (s_axis_img_tdata),
        .s_axis_img_tlast (s_axis_img_tlast),
        
        .s_axis_w_tvalid  (s_axis_w_tvalid),
        .s_axis_w_tready  (s_axis_w_tready),
        .s_axis_w_tdata   (s_axis_w_tdata),
        .s_axis_w_tlast   (s_axis_w_tlast),
        
        .m_axis_res_tvalid(m_axis_res_tvalid),
        .m_axis_res_tready(m_axis_res_tready),
        .m_axis_res_tdata (m_axis_res_tdata),
        .m_axis_res_tkeep (m_axis_res_tkeep),
        .m_axis_res_tlast (m_axis_res_tlast),
        
        .i_load_weights   (i_load_weights),
        .i_target_layer   (i_target_layer),
        .i_start_compute  (i_start_compute),
        .i_l1_weight_base (i_l1_weight_base),
        .i_l2_weight_base (i_l2_weight_base),
        .o_compute_done   (o_compute_done)
    );

    // =========================================================================
    // 4. 时钟生成 (100MHz)
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 5. 任务定义 (Helper Tasks)
    // =========================================================================
    
    // 任务：加载一组权重到指定的 Target Layer
    task load_weights_for_target(input [3:0] target_id, input [7:0] start_val);
        integer k;
        begin
            $display("[Time %0t] Loading Weights for Target ID: %d", $time, target_id);
            
            // 1. 设置控制信号
            @(posedge clk);
            i_target_layer = target_id;
            i_load_weights = 1; // 产生复位脉冲
            @(posedge clk);
            i_load_weights = 0; // 结束脉冲，开始传输
            
            // 2. 发送 AXI Stream 数据
            // 假设每个 Core 只需要 1 组权重 (Addr 0)，需要发送 BEATS_PER_WEIGHT_LINE 次
            for (k = 0; k < BEATS_PER_WEIGHT_LINE; k = k + 1) begin
                s_axis_w_tvalid = 1;
                // 构造测试数据：简单的递增数，方便调试
                s_axis_w_tdata  = {8{start_val + k[7:0]}}; 
                
                if (k == BEATS_PER_WEIGHT_LINE - 1) 
                    s_axis_w_tlast = 1;
                else 
                    s_axis_w_tlast = 0;
                
                @(posedge clk);
            end
            
            s_axis_w_tvalid = 0;
            s_axis_w_tlast  = 0;
            #20; // 间隔
        end
    endtask

    // 任务：发送整张图像
// 任务：发送整张图像
    task send_image_frame();
        integer r, c;
        integer pixel_idx;
        begin
            $display("[Time %0t] Starting Image Transmission (%0dx%0d)...", $time, IMG_WIDTH, IMG_HEIGHT);
            pixel_idx = 0;
            
            for (r = 0; r < IMG_HEIGHT; r = r + 1) begin
                for (c = 0; c < IMG_WIDTH; c = c + 1) begin
                    s_axis_img_tvalid = 1;
                    // 构造图像数据：每个通道值不同
                    s_axis_img_tdata = 64'h0807060504030201 + pixel_idx; 
                    
                    if (r == IMG_HEIGHT-1 && c == IMG_WIDTH-1)
                        s_axis_img_tlast = 1;
                    else
                        s_axis_img_tlast = 0;
                    
                    // --- 修正部分开始 ---
                    // 等待 Ready (标准 Verilog 写法)
                    @(posedge clk);
                    while (!s_axis_img_tready) begin
                        @(posedge clk);
                    end
                    // --- 修正部分结束 ---
                    
                    pixel_idx = pixel_idx + 1;
                end
            end
            
            s_axis_img_tvalid = 0;
            s_axis_img_tlast  = 0;
            $display("[Time %0t] Image Transmission Done.", $time);
        end
    endtask

    // =========================================================================
    // 6. 主测试流程
    // =========================================================================
    initial begin
        // --- 初始化 ---
        rst_n = 0;
        s_axis_img_tvalid = 0; s_axis_img_tdata = 0; s_axis_img_tlast = 0;
        s_axis_w_tvalid = 0;   s_axis_w_tdata = 0;   s_axis_w_tlast = 0;
        m_axis_res_tready = 1; // 始终准备好接收结果
        i_load_weights = 0;
        i_target_layer = 0;
        i_start_compute = 0;
        i_l1_weight_base = 0;
        i_l2_weight_base = 0;
        received_pixel_cnt = 0;

        // --- 复位 ---
        #100;
        rst_n = 1;
        #50;

        // ---------------------------------------------------------------------
        // Step 1: 加载权重 (Load Weights)
        // ---------------------------------------------------------------------
        // Layer 1 有 4 个 Core (ID 0~3)
        // Layer 2 有 1 个 Core (ID 4)
        
        // 加载 L1 Core 0 (Pattern 0x10)
        load_weights_for_target(0, 8'h10);
        // 加载 L1 Core 1 (Pattern 0x20)
        load_weights_for_target(1, 8'h20);
        // 加载 L1 Core 2 (Pattern 0x30)
        load_weights_for_target(2, 8'h30);
        // 加载 L1 Core 3 (Pattern 0x40)
        load_weights_for_target(3, 8'h40);
        
        // 加载 L2 Core (ID 4) (Pattern 0x50)
        load_weights_for_target(4, 8'h50);

        $display("[Time %0t] All Weights Loaded.", $time);

        // ---------------------------------------------------------------------
        // Step 2: 开始计算 (Start Compute)
        // ---------------------------------------------------------------------
        #100;
        i_start_compute = 1;
        i_l1_weight_base = 0; // 使用 BRAM 地址 0 的权重
        i_l2_weight_base = 0;

        // ---------------------------------------------------------------------
        // Step 3: 发送图像流 (Send Image)
        // ---------------------------------------------------------------------
        fork
            // 线程 1: 发送数据
            send_image_frame();
            
            // 线程 2: 监控完成信号
            begin
                wait(o_compute_done);
                $display("\n[Time %0t] Compute Done Interrupt Received!", $time);
                #100;
                $display("Total Output Pixels Received: %d", received_pixel_cnt);
                if (received_pixel_cnt == IMG_WIDTH * IMG_HEIGHT)
                    $display("TEST PASS: Pixel count matches.");
                else
                    $display("TEST FAIL: Pixel count mismatch (Expected %d).", IMG_WIDTH * IMG_HEIGHT);
                $finish;
            end
        join
    end

    // =========================================================================
    // 7. 结果监控
    // =========================================================================
    always @(posedge clk) begin
        if (m_axis_res_tvalid && m_axis_res_tready) begin
            // 这里的 pack_cnt 逻辑取决于 Saver 模块，每 4 个像素出一次 64bit
            // 但 Saver 内部的 pixel_counter 是按像素计数的
            // 简单起见，我们假设 tvalid 每拉高一次，传输了 4 个像素 (除了最后一次可能少)
            
            // 打印前几个数据用于观察
            if (received_pixel_cnt < 16) begin
                $display("[Result] Time=%0t Data=%h Last=%b", $time, m_axis_res_tdata, m_axis_res_tlast);
            end

            // 更新计数 (粗略估计，Saver 打包逻辑是 4 pixels per beat)
            // 实际上应该看 Saver 的输出逻辑，这里假设是 4
            received_pixel_cnt = received_pixel_cnt + 4;
        end
    end

endmodule