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
    
    // 【配置】仿真参数：16x16 图像
    parameter IMG_WIDTH       = 16;
    parameter IMG_HEIGHT      = 16;
    parameter BRAM_DEPTH      = 512;
    
    localparam TOTAL_BEATS    = IMG_WIDTH * IMG_HEIGHT; 
    parameter BEATS_PER_WEIGHT_LINE = (NUM_IN_CHANNELS * 2 * FILTER_SIZE * FILTER_SIZE * DATA_WIDTH) / AXIS_DATA_WIDTH;

    // =========================================================================
    // 2. 信号定义
    // =========================================================================
    reg clk;
    reg rst_n;
    
    reg                       s_axis_img_tvalid;
    wire                      s_axis_img_tready;
    reg [AXIS_DATA_WIDTH-1:0] s_axis_img_tdata;
    reg                       s_axis_img_tlast;

    reg                       s_axis_w_tvalid;
    wire                      s_axis_w_tready;
    reg [AXIS_DATA_WIDTH-1:0] s_axis_w_tdata;
    reg                       s_axis_w_tlast;

    wire                      m_axis_res_tvalid;
    reg                       m_axis_res_tready;
    wire [AXIS_DATA_WIDTH-1:0] m_axis_res_tdata;
    wire [AXIS_DATA_WIDTH/8-1:0] m_axis_res_tkeep;
    wire                      m_axis_res_tlast;

    reg                       i_load_weights;
    reg [3:0]                 i_target_layer;
    reg                       i_start_compute;
    reg [8:0]                 i_l1_weight_base;
    reg [8:0]                 i_l2_weight_base;
    wire                      o_compute_done;

    integer received_pixel_cnt; 
    integer beat_cnt;           
    integer error_cnt;          
    integer k, r, c, pixel_idx;
    
    // 文件句柄
    integer f_debug_windows;
    integer f_golden_log;       
    integer f_layer1_dump;      // 【新增】Layer 1 原始数据记录

    reg [63:0] golden_data [0:TOTAL_BEATS-1];

    // =========================================================================
    // 3. 内部信号统计变量
    // =========================================================================
    integer stat_l1_pack_cnt;       
    integer stat_sum_valid_cnt;     
    integer core_idx;
    
    // 临时变量移至顶层
    reg signed [34:0] current_sum_a;
    reg signed [34:0] current_sum_b;
    
    reg signed [63:0] min_val_sum_a [0:3];
    reg signed [63:0] max_val_sum_a [0:3];
    reg signed [63:0] min_val_sum_b [0:3];
    reg signed [63:0] max_val_sum_b [0:3];

    // =========================================================================
    // 4. DUT 实例化
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
        .clk(clk), .rst_n(rst_n),
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
    // 5. 初始化
    // =========================================================================
    initial begin
        f_debug_windows = $fopen("debug_windows_data.txt", "w");
        f_golden_log    = $fopen("new_golden_data_code.txt", "w");
        
        // 【新增】打开 Layer 1 原始数据记录文件
        f_layer1_dump   = $fopen("layer1_raw_sums.txt", "w");
        
        if (f_debug_windows == 0 || f_golden_log == 0 || f_layer1_dump == 0) begin
            $display("Error: Could not open file for writing");
            $stop;
        end
        
        // 写入表头
        $fwrite(f_layer1_dump, "Time_ns, Beat_Idx, Core_ID, SumA_Hex, SumB_Hex, SumA_Dec, SumB_Dec\n");

        // 初始化 Golden Data
        for (k=0; k<TOTAL_BEATS; k=k+1) golden_data[k] = 64'h0;

        stat_l1_pack_cnt   = 0;
        stat_sum_valid_cnt = 0;
        for (core_idx = 0; core_idx < 4; core_idx = core_idx + 1) begin
            min_val_sum_a[core_idx] = 64'h7FFFFFFFFFFFFFFF; 
            max_val_sum_a[core_idx] = 64'h8000000000000000; 
            min_val_sum_b[core_idx] = 64'h7FFFFFFFFFFFFFFF;
            max_val_sum_b[core_idx] = 64'h8000000000000000;
        end
        
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =========================================================================
    // 6. 辅助任务
    // =========================================================================
    task load_weights_for_target;
        input [3:0] target_id;
        input [7:0] start_val;
        reg [7:0] k_val;
        begin
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
            s_axis_img_tvalid = 0;
            s_axis_img_tlast  = 0;
            @(posedge clk);

            for (r = 0; r < IMG_HEIGHT; r = r + 1) begin
                for (c = 0; c < IMG_WIDTH; c = c + 1) begin
                    s_axis_img_tvalid = 1;
                    s_axis_img_tdata = {
                        8'd8, 8'd7, 8'd6, 8'd5, 8'd4, 8'd3, 8'd2, 
                        8'd1 + (pixel_idx[7:0] % 100) 
                    };
                    
                    if (r == IMG_HEIGHT-1 && c == IMG_WIDTH-1) s_axis_img_tlast = 1;
                    else s_axis_img_tlast = 0;

                    @(posedge clk);
                    while (s_axis_img_tready == 0) @(posedge clk);
                    pixel_idx = pixel_idx + 1;
                end
            end
            
            s_axis_img_tvalid = 0;
            s_axis_img_tdata  = 0;
            s_axis_img_tlast  = 0;
            $display("[Time %0t] Image Transmission Done.", $time);
        end
    endtask

    // =========================================================================
    // 7. 主流程
    // =========================================================================
    reg [31:0] watchdog;
    initial begin
        rst_n = 0;
        s_axis_img_tvalid = 0; s_axis_img_tdata = 0; s_axis_img_tlast = 0;
        s_axis_w_tvalid = 0;   s_axis_w_tdata = 0;   s_axis_w_tlast = 0;
        m_axis_res_tready = 1; 
        i_load_weights = 0; i_target_layer = 0; i_start_compute = 0;
        i_l1_weight_base = 0; i_l2_weight_base = 0;
        received_pixel_cnt = 0;
        beat_cnt = 0;
        error_cnt = 0;
        
        #100;
        rst_n = 1; #50;

        load_weights_for_target(0, 8'h10);
        load_weights_for_target(1, 8'h20);
        load_weights_for_target(2, 8'h30);
        load_weights_for_target(3, 8'h40);
        load_weights_for_target(4, 8'h50);

        #100;
        i_start_compute = 1;

        send_image_frame();

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
        $display("Total Beats Received: %d / %d", beat_cnt, TOTAL_BEATS);
        
        if (error_cnt == 0 && beat_cnt == TOTAL_BEATS) begin
            $display("\n[SUCCESS] ALL DATA MATCHED GOLDEN REFERENCE!");
        end else begin
            $display("\n[INFO] Mismatches expected during Golden Data Recording phase.");
        end

        // 输出内部信号统计
        $display("\n-------------------------------------------------");
        $display("          INTERNAL SIGNAL STATISTICS");
        $display("-------------------------------------------------");
        $display("[L1 OUT] r_layer1_out_packed:");
        $display("    - Valid Count    : %0d transfers (Expected %0d)", stat_l1_pack_cnt, TOTAL_BEATS);

        $display("\n[L1 SUM] Accumulator Value Ranges (Min/Max):");
        for (core_idx = 0; core_idx < 4; core_idx = core_idx + 1) begin
            $display("      [Core %0d] Sum A: [%12d, %12d]", core_idx, min_val_sum_a[core_idx], max_val_sum_a[core_idx]);
        end
        $display("=================================================");
        
        $fclose(f_debug_windows);
        $fclose(f_golden_log);
        $fclose(f_layer1_dump);
        $stop;
    end

    // =========================================================================
    // 8. 监控与录制
    // =========================================================================
    always @(posedge clk) begin
        if (m_axis_res_tvalid && m_axis_res_tready) begin
            $fwrite(f_golden_log, "golden_data[%3d] = 64'h%h;\n", beat_cnt, m_axis_res_tdata);
            if (beat_cnt < TOTAL_BEATS) begin
                if (m_axis_res_tdata !== golden_data[beat_cnt]) error_cnt = error_cnt + 1;
            end
            beat_cnt = beat_cnt + 1;
            received_pixel_cnt = received_pixel_cnt + 1; 
            if (m_axis_res_tlast) $display("[Time %0t] TLAST detected!", $time);
        end
    end

    // =========================================================================
    // 9. 内部信号采样 (监控 + 录制到文件)
    // =========================================================================
    always @(posedge clk) begin
        if (u_dut.r_layer1_valid) stat_l1_pack_cnt = stat_l1_pack_cnt + 1;

        // 【核心】捕捉 Layer 1 的原始 Sum A/B 并写入文件
        // u_dut.w_sum_a_1 是在顶层定义的 wire 数组，可以直接引用
        if (u_dut.gen_l1_cores[0].u_conv_1.o_final_valid) begin
            stat_sum_valid_cnt = stat_sum_valid_cnt + 1;
            
            for (core_idx = 0; core_idx < 4; core_idx = core_idx + 1) begin
                // 1. 统计极值
                current_sum_a = u_dut.w_sum_a_1[core_idx];
                current_sum_b = u_dut.w_sum_b_1[core_idx];
                if (current_sum_a < min_val_sum_a[core_idx]) min_val_sum_a[core_idx] = current_sum_a;
                if (current_sum_a > max_val_sum_a[core_idx]) max_val_sum_a[core_idx] = current_sum_a;
                if (current_sum_b < min_val_sum_b[core_idx]) min_val_sum_b[core_idx] = current_sum_b;
                if (current_sum_b > max_val_sum_b[core_idx]) max_val_sum_b[core_idx] = current_sum_b;

                // 2. 【新增】写入原始数据文件
                $fwrite(f_layer1_dump, "%0t, %0d, %0d, %h, %h, %0d, %0d\n", 
                    $time, 
                    stat_sum_valid_cnt, 
                    core_idx, 
                    u_dut.w_sum_a_1[core_idx], 
                    u_dut.w_sum_b_1[core_idx],
                    u_dut.w_sum_a_1[core_idx], 
                    u_dut.w_sum_b_1[core_idx]
                );
            end
        end
    end
    
    always @(posedge clk) begin
        if (u_dut.u_sys_top_l1.u_padding.o_valid) 
            $fwrite(f_debug_windows, "%h\n", u_dut.u_sys_top_l1.u_padding.o_windows_packed);
    end

endmodule
