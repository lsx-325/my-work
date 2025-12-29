module pipelined_adder_tree #(
    parameter NUM_IN     = 8,   // 并行通道数 (例如 8)
    parameter DATA_WIDTH = 32   // 输入位宽
)(
    input                                   clk,
    input                                   rst_n,
    input                                   i_valid,
    // 打包输入: [Channel_N-1 ... Channel_0]
    input      signed [NUM_IN*DATA_WIDTH-1:0] i_data_packed,
    
    output reg signed [DATA_WIDTH+$clog2(NUM_IN)-1:0] o_sum, // 自动计算输出位宽
    output reg                              o_valid
);

    // 计算 Log2 用于确定树深
    function integer clog2;
        input integer value;
        begin
            value = value - 1;
            for (clog2 = 0; value > 0; clog2 = clog2 + 1)
                value = value >> 1;
        end
    endfunction

    localparam DEPTH     = clog2(NUM_IN);
    localparam OUT_WIDTH = DATA_WIDTH + DEPTH;

    // 流水线数据寄存器数组
    reg signed [OUT_WIDTH-1:0] tree_data [DEPTH:0][NUM_IN-1:0];
    reg [DEPTH:0]              valid_pipe;

    // --- Level 0: 解包输入 ---
    integer i;
    always @(*) begin
        for (i = 0; i < NUM_IN; i = i + 1) begin
            tree_data[0][i] = $signed(i_data_packed[i*DATA_WIDTH +: DATA_WIDTH]);
        end
        valid_pipe[0] = i_valid;
    end

    // --- Generate Adder Tree ---
    genvar stage, k;
    generate
        for (stage = 0; stage < DEPTH; stage = stage + 1) begin : gen_stage
            // 当前级节点数近似计算
            localparam CURRENT_NODES = (NUM_IN + (1<<stage) - 1) >> stage;
            localparam NEXT_NODES    = (CURRENT_NODES + 1) >> 1;

            for (k = 0; k < NEXT_NODES; k = k + 1) begin : gen_adder
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        tree_data[stage+1][k] <= 'd0;
                    end else begin
                        if (2*k + 1 < CURRENT_NODES) begin
                            // 两个数相加
                            tree_data[stage+1][k] <= tree_data[stage][2*k] + tree_data[stage][2*k+1];
                        end else begin
                            // 落单的数直接传递
                            tree_data[stage+1][k] <= tree_data[stage][2*k];
                        end
                    end
                end
            end
        end
    endgenerate

    // Valid 流水线
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_pipe[DEPTH:1] <= 0;
        else        valid_pipe[DEPTH:1] <= valid_pipe[DEPTH-1:0];
    end

    // 输出
    always @(*) begin
        o_sum   = tree_data[DEPTH][0];
        o_valid = valid_pipe[DEPTH];
    end

endmodule