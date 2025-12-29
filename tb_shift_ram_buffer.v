`timescale 1ns / 1ps

module tb_shift_ram_buffer;

    // --- 1. 参数定义 ---
    parameter WIDTH = 64;
    parameter DEPTH = 256;

    // --- 2. 信号定义 ---
    reg clk;
    reg ce;
    reg [WIDTH-1:0] d;
    wire [WIDTH-1:0] q;

    // --- 3. 实例化 DUT ---
    shift_ram_buffer_counter #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH)
    ) u_dut (
        .clk(clk),
        .ce(ce),
        .d(d),
        .q(q)
    );

    // --- 4. 时钟生成 ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // --- 5. 测试逻辑 ---
    integer i;
    reg [WIDTH-1:0] expected_value;
    
    initial begin
        // 初始化
        ce = 0;
        d = 0;
        
        #20;
        $display("开始测试 shift_ram_buffer");
        $display("WIDTH=%0d, DEPTH=%0d", WIDTH, DEPTH);
        
        // === 测试 1: 简单数据测试 ===
        $display("\n[测试1] 发送连续数据");
        ce = 1;
        
        for (i = 0; i < 10; i = i + 1) begin
            d = i + 100; // 数据：100, 101, 102...
            @(posedge clk);
            $display("时间 %0t: 输入=%h, 输出=%h", $time, d, q);
        end
        
        // === 测试 2: 深度测试 ===
        $display("\n[测试2] 测试深度延迟");
        
        // 发送一个特殊值，然后等待DEPTH个周期看输出
        d = 64'hDEADBEEF;
        @(posedge clk);
        
        ce = 0; // 暂停输入
        d = 0;
        
        // 等待DEPTH个周期
        repeat(DEPTH) @(posedge clk);
        
        ce = 1;
        if (q === 64'hDEADBEEF) begin
            $display("深度测试通过: 延迟%0d个周期后输出正确", DEPTH);
        end else begin
            $display("深度测试失败: 期望=DEADBEEF, 实际=%h", q);
        end
        
        // === 测试 3: ce信号控制测试 ===
        $display("\n[测试3] 测试ce信号控制");
        
        for (i = 0; i < 20; i = i + 1) begin
            // 每隔一个周期使能一次
            ce = (i % 2 == 0);
            d = i + 200;
            @(posedge clk);
            if (ce) begin
                $display("时间 %0t: ce=1, 输入=%h, 输出=%h", $time, d, q);
            end
        end
        
        // === 测试 4: 环绕测试 ===
        $display("\n[测试4] 测试指针环绕");
        ce = 1;
        
        // 发送超过DEPTH的数据
        for (i = 0; i < DEPTH + 10; i = i + 1) begin
            d = i + 300;
            @(posedge clk);
            if (i >= DEPTH) begin
                $display("时间 %0t: 输入=%h, 输出=%h (已环绕)", $time, d, q);
            end
        end
        
        ce = 0;
        #50;
        
        $display("\n测试完成");
        $finish;
    end

endmodule