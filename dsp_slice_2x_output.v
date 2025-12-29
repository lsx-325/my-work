module dsp_slice_2x_output #(
    parameter ACCUM_WIDTH = 32,
    parameter DATA_WIDTH  = 8,
    parameter FILTER_SIZE = 3    // [修改] 卷积核边长 (例如 3 代表 3x3)
)(
    input                                clk,
    input                                rst_n,
    input                                i_valid,

    // 1. 输入：自动计算总位宽
    // 例如 3*3*8 = 72bit
    input      signed [(FILTER_SIZE*FILTER_SIZE)*DATA_WIDTH-1:0] i_window_packed,
    
    // 2. 输入：权重
    input      signed [(FILTER_SIZE*FILTER_SIZE)*DATA_WIDTH-1:0] i_kernel_A_packed,
    input      signed [(FILTER_SIZE*FILTER_SIZE)*DATA_WIDTH-1:0] i_kernel_B_packed,
    
    // 3. 输出
    output reg signed [ACCUM_WIDTH-1:0]  o_sum_A,
    output reg signed [ACCUM_WIDTH-1:0]  o_sum_B,
    
    output                               o_valid_out
);

    // =============================================================
    // 0. 常量计算 (3x3 -> 9)
    // =============================================================
    localparam NUM_POINTS = FILTER_SIZE * FILTER_SIZE;

    // =============================================================
    // 1. 解包逻辑 (Unpack)
    // =============================================================
    wire signed [DATA_WIDTH-1:0] i_kernel_A [NUM_POINTS-1:0];
    wire signed [DATA_WIDTH-1:0] i_kernel_B [NUM_POINTS-1:0];
    wire signed [DATA_WIDTH-1:0] data_window [NUM_POINTS-1:0]; 

    genvar j;
    generate
        for (j = 0; j < NUM_POINTS; j = j + 1) begin : gen_unpack
            assign i_kernel_A[j]  = i_kernel_A_packed[j*DATA_WIDTH +: DATA_WIDTH];
            assign i_kernel_B[j]  = i_kernel_B_packed[j*DATA_WIDTH +: DATA_WIDTH];
            assign data_window[j] = i_window_packed  [j*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    // =============================================================
    // 2. 流水线控制 (Pipeline Control)
    // =============================================================
    function integer clog2;
        input integer value;
        begin
            value = value - 1;
            for (clog2 = 0; value > 0; clog2 = clog2 + 1)
                value = value >> 1;
        end
    endfunction

    // DSP延迟(2) + 加法树深度
    localparam ADDER_TREE_DEPTH = clog2(NUM_POINTS);
    localparam TOTAL_LATENCY    = 2 + ADDER_TREE_DEPTH;

    reg [TOTAL_LATENCY:0] valid_pipe;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_pipe <= 0;
        else        valid_pipe <= {valid_pipe[TOTAL_LATENCY-1:0], i_valid};
    end
    
    assign o_valid_out = valid_pipe[TOTAL_LATENCY]; // S5 (对于9点)

    // =============================================================
    // 3. DSP 阵列 (乘法)
    // =============================================================
    localparam DSP_OUT_WIDTH = 16; // 8x8乘法结果
    
    wire signed [DSP_OUT_WIDTH-1:0] qa_res [NUM_POINTS-1:0];
    wire signed [DSP_OUT_WIDTH-1:0] qb_res [NUM_POINTS-1:0]; 
    
    genvar i;
    generate
        for (i = 0; i < NUM_POINTS; i = i + 1) begin : gen_dsp_array
            dsp2x8 dsp_unit_i (
                .clk(clk),
                .rst_n(rst_n),
                .CE(i_valid), 
                .D(data_window[i]), 
                .WA(i_kernel_A[i]), 
                .WB(i_kernel_B[i]),
                .QA(qa_res[i]), 
                .QB(qb_res[i])
            );
        end
    endgenerate
    
    // =============================================================
    // 4. 参数化加法树 (Adder Tree)
    // =============================================================
    localparam MAX_TREE_WIDTH = DSP_OUT_WIDTH + ADDER_TREE_DEPTH;
    
    reg signed [MAX_TREE_WIDTH-1:0] tree_A [ADDER_TREE_DEPTH:0][NUM_POINTS-1:0];
    reg signed [MAX_TREE_WIDTH-1:0] tree_B [ADDER_TREE_DEPTH:0][NUM_POINTS-1:0];

    // Level 0: 载入 DSP 结果
    integer k;
    always @(*) begin
        for (k = 0; k < NUM_POINTS; k = k + 1) begin
            tree_A[0][k] = qa_res[k];
            tree_B[0][k] = qb_res[k];
        end
    end

    // 递归生成后续级
    genvar stage, node;
    generate
        for (stage = 0; stage < ADDER_TREE_DEPTH; stage = stage + 1) begin : gen_stage
            localparam CURRENT_NODES = (NUM_POINTS + (1<<stage) - 1) >> stage;
            localparam NEXT_NODES    = (CURRENT_NODES + 1) >> 1;

            for (node = 0; node < NEXT_NODES; node = node + 1) begin : gen_adder
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        tree_A[stage+1][node] <= 0;
                        tree_B[stage+1][node] <= 0;
                    end else begin
                        if (2*node + 1 < CURRENT_NODES) begin
                            tree_A[stage+1][node] <= tree_A[stage][2*node] + tree_A[stage][2*node+1];
                            tree_B[stage+1][node] <= tree_B[stage][2*node] + tree_B[stage][2*node+1];
                        end else begin
                            tree_A[stage+1][node] <= tree_A[stage][2*node];
                            tree_B[stage+1][node] <= tree_B[stage][2*node];
                        end
                    end
                end
            end
        end
    endgenerate

    // =============================================================
    // 5. 输出赋值 (Output Register)
    // =============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_sum_A <= 0;
            o_sum_B <= 0;
        end else begin
            // 多打一拍输出寄存器，优化时序
            o_sum_A <= tree_A[ADDER_TREE_DEPTH][0];
            o_sum_B <= tree_B[ADDER_TREE_DEPTH][0];
        end
    end

endmodule