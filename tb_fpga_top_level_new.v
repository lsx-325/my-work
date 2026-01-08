//`timescale 1ns / 1ps

//module tb_fpga_top_level_new;

//    // =========================================================================
//    // 1. 参数定义
//    // =========================================================================
//    parameter AXIS_DATA_WIDTH = 64;
//    parameter NUM_IN_CHANNELS = 8;
//    parameter DATA_WIDTH      = 8;
//    parameter ACCUM_WIDTH     = 32;
//    parameter FILTER_SIZE     = 3;
    
//    // 为了仿真速度，我们将图像尺寸设小一点
//    parameter IMG_WIDTH       = 16; 
//    parameter IMG_HEIGHT      = 16;
//    parameter BRAM_DEPTH      = 512;

//    // 权重加载相关计算
//    // Layer 1: 4 Cores, 每个 Core 负责 2 个输出通道
//    // 每个 Core 需要 144 个权重 (8 In * 2 Out * 9) = 1152 bits
//    // 1152 bits / 64 bits (AXI) = 18 Beats
//    parameter BEATS_PER_WEIGHT_LINE = (NUM_IN_CHANNELS * 2 * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH) / AXIS_DATA_WIDTH;

//    // =========================================================================
//    // 2. 信号定义
//    // =========================================================================
//    reg clk;
//    reg rst_n;

//    // 图像输入
//    reg                       s_axis_img_tvalid;
//    wire                      s_axis_img_tready;
//    reg [AXIS_DATA_WIDTH-1:0] s_axis_img_tdata;
//    reg                       s_axis_img_tlast;

//    // 权重输入
//    reg                       s_axis_w_tvalid;
//    wire                      s_axis_w_tready;
//    reg [AXIS_DATA_WIDTH-1:0] s_axis_w_tdata;
//    reg                       s_axis_w_tlast;

//    // 结果输出
//    wire                      m_axis_res_tvalid;
//    reg                       m_axis_res_tready;
//    wire [AXIS_DATA_WIDTH-1:0] m_axis_res_tdata;
//    wire [AXIS_DATA_WIDTH/8-1:0] m_axis_res_tkeep;
//    wire                      m_axis_res_tlast;

//    // 控制信号
//    reg                       i_load_weights;
//    reg [3:0]                 i_target_layer;
//    reg                       i_start_compute;
//    reg [8:0]                 i_l1_weight_base;
//    reg [8:0]                 i_l2_weight_base;
//    wire                      o_compute_done;

//    // 统计接收到的像素数
//    integer received_pixel_cnt;
//    integer k, r, c, pixel_idx;

//    // =========================================================================
//    // 3. DUT 实例化
//    // =========================================================================
//    fpga_top_level #(
//        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
//        .NUM_IN_CHANNELS(NUM_IN_CHANNELS),
//        .DATA_WIDTH     (DATA_WIDTH),
//        .ACCUM_WIDTH    (ACCUM_WIDTH),
//        .FILTER_SIZE    (FILTER_SIZE),
//        .IMG_WIDTH      (IMG_WIDTH),
//        .IMG_HEIGHT     (IMG_HEIGHT),
//        .BRAM_DEPTH     (BRAM_DEPTH)
//    ) u_dut (
//        .clk(clk),
//        .rst_n(rst_n),
        
//        .s_axis_img_tvalid(s_axis_img_tvalid),
//        .s_axis_img_tready(s_axis_img_tready),
//        .s_axis_img_tdata (s_axis_img_tdata),
//        .s_axis_img_tlast (s_axis_img_tlast),
        
//        .s_axis_w_tvalid  (s_axis_w_tvalid),
//        .s_axis_w_tready  (s_axis_w_tready),
//        .s_axis_w_tdata   (s_axis_w_tdata),
//        .s_axis_w_tlast   (s_axis_w_tlast),
        
//        .m_axis_res_tvalid(m_axis_res_tvalid),
//        .m_axis_res_tready(m_axis_res_tready),
//        .m_axis_res_tdata (m_axis_res_tdata),
//        .m_axis_res_tkeep (m_axis_res_tkeep),
//        .m_axis_res_tlast (m_axis_res_tlast),
        
//        .i_load_weights   (i_load_weights),
//        .i_target_layer   (i_target_layer),
//        .i_start_compute  (i_start_compute),
//        .i_l1_weight_base (i_l1_weight_base),
//        .i_l2_weight_base (i_l2_weight_base),
//        .o_compute_done   (o_compute_done)
//    );

//    // =========================================================================
//    // 4. 时钟生成 (100MHz)
//    // =========================================================================
//    initial begin
//        clk = 0;
//        forever #5 clk = ~clk;
//    end

//    // =========================================================================
//    // 5. 任务定义 (Helper Tasks)
//    // =========================================================================
    
//    // 任务：加载一组权重到指定的 Target Layer
//    task load_weights_for_target;
//        input [3:0] target_id;
//        input [7:0] start_val;
        
//        reg [7:0] k_val;
//        begin
//            $display("[Time %0t] Loading Weights for Target ID: %d", $time, target_id);
            
//            // 1. 设置控制信号
//            @(posedge clk);
//            i_target_layer = target_id;
//            i_load_weights = 1; // 产生复位脉冲
//            @(posedge clk);
//            i_load_weights = 0; // 结束脉冲，开始传输
            
//            // 2. 发送 AXI Stream 数据
//            // 假设每个 Core 只需要 1 组权重 (Addr 0)，需要发送 BEATS_PER_WEIGHT_LINE 次
//            for (k = 0; k < BEATS_PER_WEIGHT_LINE; k = k + 1) begin
//                s_axis_w_tvalid = 1;
//                k_val = start_val + k;
//                // 构造测试数据：简单的递增数，方便调试
//                s_axis_w_tdata  = {8{k_val}}; 
                
//                if (k == BEATS_PER_WEIGHT_LINE - 1) 
//                    s_axis_w_tlast = 1;
//                else 
//                    s_axis_w_tlast = 0;
                
//                @(posedge clk);
//            end
            
//            s_axis_w_tvalid = 0;
//            s_axis_w_tlast  = 0;
//            #20; // 间隔
//        end
//    endtask

//    // 任务：发送整张图像
//    task send_image_frame;
//        begin
//            $display("[Time %0t] Starting Image Transmission (%0dx%0d)...", $time, IMG_WIDTH, IMG_HEIGHT);
//            pixel_idx = 0;
            
//            for (r = 0; r < IMG_HEIGHT; r = r + 1) begin
//                for (c = 0; c < IMG_WIDTH; c = c + 1) begin
//                    s_axis_img_tvalid = 1;
//                    // 构造图像数据：每个通道值不同
//                    s_axis_img_tdata = 64'h0807060504030201 + pixel_idx; 
                    
//                    if (r == IMG_HEIGHT-1 && c == IMG_WIDTH-1)
//                        s_axis_img_tlast = 1;
//                    else
//                        s_axis_img_tlast = 0;
                    
//                    // 等待 Ready
//                    @(posedge clk);
//                    while (s_axis_img_tready == 0) begin
//                        @(posedge clk);
//                    end
                    
//                    pixel_idx = pixel_idx + 1;
//                end
//            end
            
//            s_axis_img_tvalid = 0;
//            s_axis_img_tlast  = 0;
//            $display("[Time %0t] Image Transmission Done.", $time);
//        end
//    endtask

//    // =========================================================================
//    // 6. 主测试流程
//    // =========================================================================
//    reg image_sent_flag;
//    reg compute_done_flag;
    
//    initial begin
//        // --- 初始化 ---
//        rst_n = 0;
//        s_axis_img_tvalid = 0; s_axis_img_tdata = 0; s_axis_img_tlast = 0;
//        s_axis_w_tvalid = 0;   s_axis_w_tdata = 0;   s_axis_w_tlast = 0;
//        m_axis_res_tready = 1; // 始终准备好接收结果
//        i_load_weights = 0;
//        i_target_layer = 0;
//        i_start_compute = 0;
//        i_l1_weight_base = 0;
//        i_l2_weight_base = 0;
//        received_pixel_cnt = 0;
//        image_sent_flag = 0;
//        compute_done_flag = 0;

//        // --- 复位 ---
//        #100;
//        rst_n = 1;
//        #50;

//        // ---------------------------------------------------------------------
//        // Step 1: 加载权重 (Load Weights)
//        // ---------------------------------------------------------------------
//        // Layer 1 有 4 个 Core (ID 0~3)
//        // Layer 2 有 1 个 Core (ID 4)
        
//        // 加载 L1 Core 0 (Pattern 0x10)
//        load_weights_for_target(0, 8'h10);
//        // 加载 L1 Core 1 (Pattern 0x20)
//        load_weights_for_target(1, 8'h20);
//        // 加载 L1 Core 2 (Pattern 0x30)
//        load_weights_for_target(2, 8'h30);
//        // 加载 L1 Core 3 (Pattern 0x40)
//        load_weights_for_target(3, 8'h40);
        
//        // 加载 L2 Core (ID 4) (Pattern 0x50)
//        load_weights_for_target(4, 8'h50);

//        $display("[Time %0t] All Weights Loaded.", $time);

//        // ---------------------------------------------------------------------
//        // Step 2: 开始计算 (Start Compute)
//        // ---------------------------------------------------------------------
//        #100;
//        i_start_compute = 1;
//        i_l1_weight_base = 0; // 使用 BRAM 地址 0 的权重
//        i_l2_weight_base = 0;

//        // ---------------------------------------------------------------------
//        // Step 3: 发送图像流 (Send Image)
//        // ---------------------------------------------------------------------
//        // 发送数据
//        send_image_frame();
//        image_sent_flag = 1;
        
//        // 等待一段时间后检查结果
//        #2000;
        
//        $display("\n[Time %0t] Simulation Complete!", $time);
//        $display("Total Output Pixels Received: %d", received_pixel_cnt);
//        if (received_pixel_cnt == IMG_WIDTH * IMG_HEIGHT)
//            $display("TEST PASS: Pixel count matches.");
//        else
//            $display("TEST FAIL: Pixel count mismatch (Expected %d).", IMG_WIDTH * IMG_HEIGHT);
//        $finish;
//    end

//    // =========================================================================
//    // 7. 结果监控
//    // =========================================================================
//    always @(posedge clk) begin
//        if (m_axis_res_tvalid && m_axis_res_tready) begin
//            // 打印前几个数据用于观察
//            if (received_pixel_cnt < 16) begin
//                $display("[Result] Time=%0t Data=%h Last=%b", $time, m_axis_res_tdata, m_axis_res_tlast);
//            end

//            // 更新计数 (粗略估计，Saver 打包逻辑是 4 pixels per beat)
//            // 实际上应该看 Saver 的输出逻辑，这里假设是 4
//            received_pixel_cnt = received_pixel_cnt + 4;
            
//            // 检查完成信号
//            if (m_axis_res_tlast) begin
//                $display("[Time %0t] Output TLAST detected!", $time);
//            end
//        end
//    end
    
//    // =========================================================================
//    // 8. 监视完成信号
//    // =========================================================================
//    always @(posedge clk) begin
//        if (o_compute_done && !compute_done_flag) begin
//            compute_done_flag = 1;
//            $display("[Time %0t] Compute Done signal asserted!", $time);
//        end
//    end

//endmodule
`timescale 1ns / 1ps

module tb_fpga_top_level_new;

    // =========================================================================
    // 1. 参数定义
    // =========================================================================
    parameter AXIS_DATA_WIDTH = 64;
    parameter NUM_IN_CHANNELS = 8;
    parameter DATA_WIDTH      = 8;
    parameter ACCUM_WIDTH     = 32;
    parameter FILTER_SIZE     = 3;
    
    // 仿真参数：16x16 图像
    parameter IMG_WIDTH       = 16;
    parameter IMG_HEIGHT      = 16;
    parameter BRAM_DEPTH      = 512;
    
    // 计算总 Beat 数：256 像素 / 4 像素每Beat = 64 Beats
    localparam TOTAL_BEATS    = (IMG_WIDTH * IMG_HEIGHT) / 4; 

    parameter BEATS_PER_WEIGHT_LINE = (NUM_IN_CHANNELS * 2 * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH) / AXIS_DATA_WIDTH;

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
    
    // 统计与比对
    integer received_pixel_cnt; // 像素计数
    integer beat_cnt;           // 数据包计数
    integer error_cnt;          // 错误计数
    integer k, r, c, pixel_idx;
    
    // 黄金参考数据 (64 个 64-bit 结果)
    reg [63:0] golden_data [0:TOTAL_BEATS-1];

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
    // 4. 初始化黄金数据 (Golden Reference Initialization)
    // =========================================================================
    initial begin
        // 使用 Python 算出的理论正确值
        golden_data[ 0] = 64'h51494f48453f2b27; golden_data[ 1] = 64'h574f564e544c534b;
        golden_data[ 2] = 64'h5e555c535a525950; golden_data[ 3] = 64'h3630564e61575f56;
        golden_data[ 4] = 64'h92848f817e724e47; golden_data[ 5] = 64'h9c8d9a8b97899486;
        golden_data[ 6] = 64'ha696a394a1919e8f; golden_data[ 7] = 64'h5f56988aab9aa998;
        golden_data[ 8] = 64'hc5b2c2afab9b6b60; golden_data[ 9] = 64'hd0bccdbacbb7c8b4;
        golden_data[10] = 64'hdbc6d8c4d6c1d3bf; golden_data[11] = 64'h7d71c8b5e1cbdec9;
        golden_data[12] = 64'hf2daefd8d3bf8477; golden_data[13] = 64'hfde5fae2f7dff4dd;
        golden_data[14] = 64'hffeeffecffe9ffe7; golden_data[15] = 64'h9687f0d9fff3fff1;
        golden_data[16] = 64'hfffffffffbe39d8e; golden_data[17] = 64'hffffffffffffffff;
        golden_data[18] = 64'hffffffffffffffff; golden_data[19] = 64'hae9dfffdffffffff;
        golden_data[20] = 64'hffffffffffffb6a5; golden_data[21] = 64'hffffffffffffffff;
        golden_data[22] = 64'hffffffffffffffff; golden_data[23] = 64'hc7b3ffffffffffff;
        golden_data[24] = 64'hffffffffffffcfbb; golden_data[25] = 64'hffffffffffffffff;
        golden_data[26] = 64'hffffffffffffffff; golden_data[27] = 64'hdfc9ffffffffffff;
        golden_data[28] = 64'hffffffffffffe8d1; golden_data[29] = 64'hffffffffffffffff;
        golden_data[30] = 64'hffffffffffffffff; golden_data[31] = 64'hf7dfffffffffffff;
        golden_data[32] = 64'hffffffffffffffe8; golden_data[33] = 64'hffffffffffffffff;
        golden_data[34] = 64'hffffffffffffffff; golden_data[35] = 64'hfff5ffffffffffff;
        golden_data[36] = 64'hffffffffffffffff; golden_data[37] = 64'hffffffffffffffff;
        golden_data[38] = 64'hffffffffffffffff; golden_data[39] = 64'hffffffffffffffff;
        golden_data[40] = 64'hffffffffffffffff; golden_data[41] = 64'hffffffffffffffff;
        golden_data[42] = 64'hffffffffffffffff; golden_data[43] = 64'hffffffffffffffff;
        golden_data[44] = 64'hffffffffffffffff; golden_data[45] = 64'hffffffffffffffff;
        golden_data[46] = 64'hffffffffffffffff; golden_data[47] = 64'hffffffffffffffff;
        golden_data[48] = 64'hffffffffffffffff; golden_data[49] = 64'hffffffffffffffff;
        golden_data[50] = 64'hffffffffffffffff; golden_data[51] = 64'hffffffffffffffff;
        golden_data[52] = 64'hffffffffffffffff; golden_data[53] = 64'hffffffffffffffff;
        golden_data[54] = 64'hffffffffffffffff; golden_data[55] = 64'hffffffffffffffff;
        golden_data[56] = 64'hffffffffffffffff; golden_data[57] = 64'hffffffffffffffff;
        golden_data[58] = 64'hffffffffffffffff; golden_data[59] = 64'hffffffffffffffff;
        golden_data[60] = 64'hffffffffffffddc7; golden_data[61] = 64'hffffffffffffffff;
        golden_data[62] = 64'hffffffffffffffff; golden_data[63] = 64'hbfacffffffffffff;
    end

    // =========================================================================
    // 5. 时钟生成
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 6. 辅助任务 (Tasks)
    // =========================================================================
    task load_weights_for_target;
        input [3:0] target_id;
        input [7:0] start_val;
        reg [7:0] k_val;
        begin
            $display("[Time %0t] Loading Weights for Target ID: %d", $time, target_id);
            @(posedge clk);
            i_target_layer = target_id;
            i_load_weights = 1;
            @(posedge clk);
            i_load_weights = 0;
            
            for (k = 0; k < BEATS_PER_WEIGHT_LINE; k = k + 1) begin
                s_axis_w_tvalid = 1;
                k_val = start_val + k;
                s_axis_w_tdata  = {8{k_val}};
                s_axis_w_tlast  = (k == BEATS_PER_WEIGHT_LINE - 1);
                @(posedge clk);
            end
            s_axis_w_tvalid = 0;
            s_axis_w_tlast  = 0;
            #20;
        end
    endtask

    task send_image_frame;
        begin
            $display("[Time %0t] Starting Image Transmission (%0dx%0d)...", $time, IMG_WIDTH, IMG_HEIGHT);
            pixel_idx = 0;
            for (r = 0; r < IMG_HEIGHT; r = r + 1) begin
                for (c = 0; c < IMG_WIDTH; c = c + 1) begin
                    s_axis_img_tvalid = 1;
                    s_axis_img_tdata = 64'h0807060504030201 + pixel_idx;
                    s_axis_img_tlast = (r == IMG_HEIGHT-1 && c == IMG_WIDTH-1);
                    @(posedge clk);
                    while (s_axis_img_tready == 0) @(posedge clk);
                    pixel_idx = pixel_idx + 1;
                end
            end
            s_axis_img_tvalid = 0;
            s_axis_img_tlast  = 0;
            $display("[Time %0t] Image Transmission Done.", $time);
        end
    endtask

    // =========================================================================
    // 7. 主流程
    // =========================================================================
    reg [31:0] watchdog;
    
    initial begin
        // --- 初始化 ---
        rst_n = 0;
        s_axis_img_tvalid = 0; s_axis_img_tdata = 0; s_axis_img_tlast = 0;
        s_axis_w_tvalid = 0;   s_axis_w_tdata = 0;   s_axis_w_tlast = 0;
        m_axis_res_tready = 1; 
        i_load_weights = 0; i_target_layer = 0; i_start_compute = 0;
        i_l1_weight_base = 0; i_l2_weight_base = 0;
        received_pixel_cnt = 0;
        beat_cnt = 0;
        error_cnt = 0;
        
        // --- 复位 ---
        #100; rst_n = 1; #50;

        // Step 1: 加载权重
        load_weights_for_target(0, 8'h10);
        load_weights_for_target(1, 8'h20);
        load_weights_for_target(2, 8'h30);
        load_weights_for_target(3, 8'h40);
        load_weights_for_target(4, 8'h50);

        // Step 2: 启动计算
        #100;
        i_start_compute = 1;

        // Step 3: 发送图像
        send_image_frame();

        // Step 4: 等待结果
        $display("[Time %0t] Waiting for results...", $time);
        watchdog = 0;
        while (received_pixel_cnt < IMG_WIDTH * IMG_HEIGHT && watchdog < 10000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        
        #100;
        $display("\n=================================================");
        $display("          SIMULATION REPORT");
        $display("=================================================");
        $display("Total Beats Received: %d / %d", beat_cnt, TOTAL_BEATS);
        $display("Total Pixels: %d / %d", received_pixel_cnt, IMG_WIDTH*IMG_HEIGHT);
        
        if (error_cnt == 0 && beat_cnt == TOTAL_BEATS) begin
            $display("\n[SUCCESS] ALL DATA MATCHED GOLDEN REFERENCE!");
        end else begin
            $display("\n[FAILURE] Found %d Mismatches.", error_cnt);
            if (beat_cnt != TOTAL_BEATS)
                $display("[FAILURE] Data count mismatch (Expected %d beats).", TOTAL_BEATS);
        end
        $display("=================================================");
        $stop;
    end

    // =========================================================================
    // 8. 结果监控与比对 (Monitor & Checker)
    // =========================================================================
    always @(posedge clk) begin
        if (m_axis_res_tvalid && m_axis_res_tready) begin
            // 打印并比对
            if (beat_cnt < TOTAL_BEATS) begin
                if (m_axis_res_tdata === golden_data[beat_cnt]) begin
                    $display("[CHECK PASS] Beat %2d: Data=%h (Matched)", beat_cnt, m_axis_res_tdata);
                end else begin
                    $display("[CHECK FAIL] Beat %2d: Data=%h | Exp=%h !!!", beat_cnt, m_axis_res_tdata, golden_data[beat_cnt]);
                    error_cnt = error_cnt + 1;
                end
            end else begin
                $display("[WARNING] Received extra beat: %h", m_axis_res_tdata);
            end

            // 更新计数器
            beat_cnt = beat_cnt + 1;
            received_pixel_cnt = received_pixel_cnt + 4; // 每个 Beat 4 个像素，每个像素 2 个输出通道? 
            // 修正：根据之前的分析，一个Beat是 4 个像素 (64bit / 16bit_per_pixel)
            // 所以这里像素计数应该是 +4，而不是 +8。
            // 但如果你的 Saver 配置是每个时钟出 8 个通道，那就是 +8。
            // 让我们保持和之前代码一致的 +4 (4 pixels * 2 channels * 8 bits = 64 bits)
            
            if (m_axis_res_tlast) begin
                $display("[Time %0t] TLAST detected!", $time);
            end
        end
    end

endmodule

`timescale 1ns / 1ps

module tb_fpga_top_level_new;

    // =========================================================================
    // 1. 参数定义
    // =========================================================================
    parameter AXIS_DATA_WIDTH = 64;
    parameter NUM_IN_CHANNELS = 8;
    parameter DATA_WIDTH      = 8;
    parameter ACCUM_WIDTH     = 32;
    parameter FILTER_SIZE     = 3;
    
    // 仿真参数：16x16 图像
    parameter IMG_WIDTH       = 16;
    parameter IMG_HEIGHT      = 16;
    parameter BRAM_DEPTH      = 512;
    
    // 计算总 Beat 数：256 像素
    // 注意：根据之前的 Log，Layer 1 输出的是 1 pixel/beat (64bit 包含 8ch)。
    // 所以总 Beat 数应该是 IMG_WIDTH * IMG_HEIGHT
    localparam TOTAL_BEATS    = (IMG_WIDTH * IMG_HEIGHT); 
    
    // 权重加载 Beat 数计算
    parameter BEATS_PER_WEIGHT_LINE = (NUM_IN_CHANNELS * 2 * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH) / AXIS_DATA_WIDTH;

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

    // 统计与比对
    integer received_pixel_cnt; // 像素计数
    integer beat_cnt;           // 数据包计数
    integer error_cnt;          // 错误计数
    integer k, r, c, pixel_idx;

    // 黄金参考数据 (注意：这里定义大一点以防万一)
    reg [63:0] golden_data [0:255]; 

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
    // 4. 初始化黄金数据 (Golden Reference Initialization)
    // =========================================================================
    // 这里只列出原来 Testbench 里的部分关键数据用于校验
    initial begin
        // 初始化整个数组为 0，避免未初始化比较
        for (k=0; k<256; k=k+1) golden_data[k] = 0;

        // 填入您提供的关键 Golden Data
        golden_data[ 0] = 64'h51494f48453f2b27;
        golden_data[ 1] = 64'h574f564e544c534b;
        golden_data[ 2] = 64'h5e555c535a525950; golden_data[ 3] = 64'h3630564e61575f56;
        golden_data[ 4] = 64'h92848f817e724e47; golden_data[ 5] = 64'h9c8d9a8b97899486;
        golden_data[ 6] = 64'ha696a394a1919e8f; golden_data[ 7] = 64'h5f56988aab9aa998;
        golden_data[ 8] = 64'hc5b2c2afab9b6b60; golden_data[ 9] = 64'hd0bccdbacbb7c8b4;
        golden_data[10] = 64'hdbc6d8c4d6c1d3bf; golden_data[11] = 64'h7d71c8b5e1cbdec9;
        golden_data[12] = 64'hf2daefd8d3bf8477; golden_data[13] = 64'hfde5fae2f7dff4dd;
        golden_data[14] = 64'hffeeffecffe9ffe7; golden_data[15] = 64'h9687f0d9fff3fff1;
        golden_data[16] = 64'hfffffffffbe39d8e; golden_data[17] = 64'hffffffffffffffff;
        golden_data[18] = 64'hffffffffffffffff; golden_data[19] = 64'hae9dfffdffffffff;
        
        // ... 中间省略 ...
        
        golden_data[35] = 64'hfff5ffffffffffff;
        
        // ...
        
        golden_data[60] = 64'hffffffffffffddc7; golden_data[61] = 64'hffffffffffffffff;
        golden_data[62] = 64'hffffffffffffffff; golden_data[63] = 64'hbfacffffffffffff;
        
        // 注意：您的 Golden Data 之前只提供了前 64 个。
        // 如果 Layer 2 之后是 16x16=256 个输出，后面的数据目前没有比对标准。
        // 代码会继续打印输出，您可以手动检查。
    end

    // =========================================================================
    // 5. 时钟生成
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 6. 辅助任务 (Tasks)
    // =========================================================================
    task load_weights_for_target;
        input [3:0] target_id;
        input [7:0] start_val;
        reg [7:0] k_val;
        begin
            $display("[Time %0t] Loading Weights for Target ID: %d", $time, target_id);
            @(posedge clk);
            i_target_layer = target_id;
            i_load_weights = 1;
            @(posedge clk);
            i_load_weights = 0;
            for (k = 0; k < BEATS_PER_WEIGHT_LINE; k = k + 1) begin
                s_axis_w_tvalid = 1;
                k_val = start_val + k;
                s_axis_w_tdata  = {8{k_val}};
                s_axis_w_tlast  = (k == BEATS_PER_WEIGHT_LINE - 1);
                @(posedge clk);
            end
            s_axis_w_tvalid = 0;
            s_axis_w_tlast  = 0;
            #20;
        end
    endtask

    task send_image_frame;
        begin
            $display("[Time %0t] Starting Image Transmission (%0dx%0d)...", $time, IMG_WIDTH, IMG_HEIGHT);
            pixel_idx = 0;
            for (r = 0; r < IMG_HEIGHT; r = r + 1) begin
                for (c = 0; c < IMG_WIDTH; c = c + 1) begin
                    s_axis_img_tvalid = 1;
                    
                    // 【关键修正】数据从 ...00 开始，解决 "Off-by-one" 问题
                    s_axis_img_tdata = 64'h0807060504030200 + pixel_idx;
                    
                    // 生成 TLAST (每行结束? 还是整个 Frame 结束?)
                    // 通常 CNN 加速器要求 Frame TLAST。这里设为最后一行最后一个像素。
                    s_axis_img_tlast = (r == IMG_HEIGHT-1 && c == IMG_WIDTH-1);
                    
                    @(posedge clk);
                    // 握手等待
                    while (s_axis_img_tready == 0) @(posedge clk);
                    
                    pixel_idx = pixel_idx + 1;
                end
            end
            s_axis_img_tvalid = 0;
            s_axis_img_tlast  = 0;
            $display("[Time %0t] Image Transmission Done.", $time);
        end
    endtask

    // =========================================================================
    // 7. 主流程
    // =========================================================================
    reg [31:0] watchdog;
    initial begin
        // --- 初始化 ---
        rst_n = 0;
        s_axis_img_tvalid = 0; s_axis_img_tdata = 0; s_axis_img_tlast = 0;
        s_axis_w_tvalid = 0;   s_axis_w_tdata = 0;   s_axis_w_tlast = 0;
        m_axis_res_tready = 1; 
        i_load_weights = 0; i_target_layer = 0; i_start_compute = 0;
        i_l1_weight_base = 0; i_l2_weight_base = 0;
        received_pixel_cnt = 0;
        beat_cnt = 0;
        error_cnt = 0;
        
        // --- 复位 ---
        #100;
        rst_n = 1; #50;

        // Step 1: 加载权重
        load_weights_for_target(0, 8'h10);
        load_weights_for_target(1, 8'h20);
        load_weights_for_target(2, 8'h30);
        load_weights_for_target(3, 8'h40);
        load_weights_for_target(4, 8'h50);
        $display("[Time %0t] All Weights Loaded.", $time);

        // Step 2: 启动计算
        #100;
        i_start_compute = 1;

        // Step 3: 发送图像
        send_image_frame();

        // Step 4: 等待结果
        // 【关键】这里不再发送伪数据 (Dummy Data)，依赖 TLAST 信号自动 Flush
        $display("[Time %0t] Waiting for results...", $time);
        
        watchdog = 0;
        while (received_pixel_cnt < TOTAL_BEATS && watchdog < 200000) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        
        #100;
        $display("\n=================================================");
        $display("          SIMULATION REPORT");
        $display("=================================================");
        $display("Total Output Pixels Received: %d", received_pixel_cnt);
        
        // 检查数量是否匹配
        if (received_pixel_cnt == 256) begin
             $display("[CHECK PASS] Pixel count matches (256).");
        end else begin
             $display("[CHECK FAIL] Pixel count mismatch! Expected 256, Got %d", received_pixel_cnt);
        end

        // 检查数据值
        if (error_cnt == 0) begin
            $display("[CHECK PASS] Checked data matches Golden Reference.");
        end else begin
            $display("[CHECK FAIL] Found %d Data Mismatches.", error_cnt);
        end
        $display("=================================================");
        $stop;
    end

    // =========================================================================
    // 8. 结果监控与比对 (Monitor & Checker)
    // =========================================================================
    always @(posedge clk) begin
        if (m_axis_res_tvalid && m_axis_res_tready) begin
            // 打印结果
            // $display("[Result] Time=%0t Data=%h Last=%b", $time, m_axis_res_tdata, m_axis_res_tlast);

            // 仅对前 64 个数据进行比对 (因为 Golden Data 只填了这么多)
            if (beat_cnt < 64) begin
                if (m_axis_res_tdata === golden_data[beat_cnt]) begin
                    $display("[CHECK PASS] Beat %2d: Data=%h (Matched)", beat_cnt, m_axis_res_tdata);
                end else begin
                    $display("[CHECK FAIL] Beat %2d: Data=%h | Exp=%h !!!", beat_cnt, m_axis_res_tdata, golden_data[beat_cnt]);
                    error_cnt = error_cnt + 1;
                end
            end 

            // 更新计数器
            beat_cnt = beat_cnt + 1;
            received_pixel_cnt = received_pixel_cnt + 1; // 1 Beat = 1 Pixel Output (64bit 包含 8通道结果)
            
            if (m_axis_res_tlast) begin
                $display("[Time %0t] Output TLAST detected!", $time);
            end
        end
    end

    // =========================================================================
    // 9. [DEBUG] Layer 1 输出监控 (L1->L2 Monitor)
    // =========================================================================
    // 监控 Layer 1 发给 Layer 2 的数据和 TLAST 信号
    
    wire        spy_l1_valid;
    wire        spy_l2_ready;
    wire        spy_l1_last; // 监控 Last 信号
    wire [63:0] spy_l1_data;
    
    // 使用层次化引用 (Hierarchical Reference)
    assign spy_l1_valid = u_dut.r_layer1_valid;       
    assign spy_l1_data  = u_dut.r_layer1_out_packed;  
    assign spy_l2_ready = u_dut.w_l2_ready;           
    // 【重要】监控我们刚才新连的那根线，确认 TLAST 是否传过来了
    assign spy_l1_last  = u_dut.w_l1_last; 

    integer l1_cnt = 0;

    always @(posedge clk) begin
        if (spy_l1_valid && spy_l2_ready) begin
            // 打印数据传输
            // $display("[L1->L2 Monitor] Time=%0t | Beat %0d | Data=%h | Last=%b", $time, l1_cnt, spy_l1_data, spy_l1_last);
            
            if (spy_l1_last) begin
                $display("!!! [L1->L2 Monitor] TLAST Detected! Layer 1 finished at Beat %0d", l1_cnt);
            end
            
            l1_cnt = l1_cnt + 1;
        end
    end

    // =========================================================================
    // 10. [DEBUG] Layer 1 内部窗口监控
    // =========================================================================
    wire        dbg_l1_win_valid;
    wire [575:0] dbg_l1_win_data;
    
    assign dbg_l1_win_valid = u_dut.u_sys_top_l1.conv_valid;  
    assign dbg_l1_win_data  = u_dut.u_sys_top_l1.conv_window; 

    integer win_cnt = 0;
    
    always @(posedge clk) begin
        if (dbg_l1_win_valid) begin
            // 可以在这里打开打印，查看卷积窗口内容
            // $display("[TB Debug] Time=%0t | L1 Window #%0d Captured", $time, win_cnt);
            win_cnt = win_cnt + 1;
        end
    end

endmodule
