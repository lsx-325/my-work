//module dsp2x8 (                                         // 两个8bit乘法共用一个DSP,输出位宽15位
//    input                   clk  ,
//    input                   rst_n,
//    input                   CE   ,
//    input  signed [8-1:0]   D    ,
//    input  signed [8-1:0]   WA   ,
//    input  signed [8-1:0]   WB   ,
//    output        [15-1:0]    QA   ,
//    output        [15-1:0]    QB
//);
    
//    reg  signed [23:0] w;
//    reg  signed [7:0]  d_r;
//    (* use_dsp="yes" *)
//    reg  signed [32:0] res;
//    wire signed [16-1:0] qb;
//    reg  ce_r;
    
//    assign QA = (^res[15:14])? 15'd16383: res[14:0];
//    assign QB = (^qb[15:14])? 15'd16383: qb[14:0];
//    assign qb = res[31:16] + res[15]; 

//    always @ (posedge clk)
//        if (!rst_n)
//            ce_r <= 'b0;
//        else
//            ce_r <= CE;
    
//    always @ (posedge clk)
//        if (CE) begin
//            d_r <= D;
//            w   <= WA + (WB <<< 16);
//        end
        
//    always @ (posedge clk)
//        if (ce_r)
//            res <= d_r * w;
            
//endmodule
//// 例化模板
///*
//    dsp2x8 dsp2x8_u (
//        .clk  (clk  ), // input
//        .CE   (CE   ), // input                
//        .D    (D    ), // input  signed [7:0]  
//        .WA   (WA   ), // input  signed [7:0]  
//        .WB   (WB   ), // input  signed [7:0]
//        .QA   (QA   ), // output        [15:0] 
//        .QB   (QB   )  // output        [15:0] 
//    );
//*/
module dsp2x8 (                        //// 两个8bit乘法共用一个DSP,输出位宽16位                         
    input                  clk  ,
    input                  rst_n,
    input                  CE   ,
    input  signed [7:0]    D    ,
    input  signed [7:0]    WA   ,
    input  signed [7:0]    WB   ,
    output signed [15:0]   QA   , // 修改点1：输出位宽改为 16 bit
    output signed [15:0]   QB     // 修改点1：输出位宽改为 16 bit
);

    // 修改点2：核心修复！w 扩展为 25 bit
    // 25 bit 范围：-16,777,216 到 +16,777,215
    // 足以容纳 (-128 << 16) + (-1) = -8,388,609，避免溢出为正数
    reg  signed [24:0] w;     
    
    reg  signed [7:0]  d_r;
    
    // 33 bit (8 bit * 25 bit) 刚好适配 DSP48
    (* use_dsp="yes" *)
    reg  signed [32:0] res;   
    
    wire signed [15:0] qb_wire; // 内部 wire 也改为 16 bit
    reg  ce_r;

    // 修改点3：移除 15-bit 饱和截断逻辑
    // 如果 QA/QB 是 16-bit，则可以直接输出，无需检查 res[15:14] 的溢出
    assign QA = res[15:0]; 
    assign QB = qb_wire;

    // 高位提取逻辑保持不变：
    // 使用 res[15] (低位部分的符号位) 来修正高位
    assign qb_wire = res[31:16] + res[15];

    always @ (posedge clk)
        if (!rst_n)
            ce_r <= 'b0;
        else
            ce_r <= CE;

    always @ (posedge clk)
        if (CE) begin
            d_r <= D;
            // 修改点2原理：
            // WB(8bit) 左移 16 位后，Verilog 会自动将其在 25-bit 上下文中运算
            // 能够正确处理符号位借位
            w   <= WA + (WB <<< 16);
        end
        
    always @ (posedge clk)
        if (ce_r)
            res <= d_r * w; 

endmodule