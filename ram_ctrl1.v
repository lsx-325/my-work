`timescale 1ns / 1ps
module ram_ctrl1
(
    input  wire        clk_50m ,
    input  wire        rst_n ,
    
    input  wire [63:0] ram1_rd_data, 
    input  wire [63:0] ram2_rd_data, 
    output wire [63:0] ram1_wr_data, 
    output wire [63:0] ram2_wr_data, 
    
    output reg         ram1_wr_en , 
    output reg         ram1_rd_en , 
    output reg  [5:0]  ram1_wr_addr, 
    output reg  [5:0]  ram1_rd_addr, 
    output reg         ram2_wr_en , 
    output reg         ram2_rd_en , 
    output reg  [5:0]  ram2_wr_addr, 
    output reg  [5:0]  ram2_rd_addr, 
    
    input  wire        data_en ,       
    input  wire [63:0] data_in ,       
    output reg         o_upstream_ready, 
    
    input  wire        i_downstream_ready, 
    output wire         o_data_valid,    // 注意：这里是 reg
    output reg  [63:0] data_out            
);

    parameter   IDLE        = 4'b0001, 
                WRAM1       = 4'b0010, 
                WRAM2_RRAM1 = 4'b0100, 
                WRAM1_RRAM2 = 4'b1000; 

    localparam CNT_MAX = 6'd63; 

    reg [3:0] state ; 
    reg [63:0] data_in_reg ; 
    reg ram1_rd_done;
    reg ram2_rd_done;

    // 写数据
    assign ram1_wr_data = (ram1_wr_en) ? data_in_reg : 64'd0;
    assign ram2_wr_data = (ram2_wr_en) ? data_in_reg : 64'd0;

    always@(posedge clk_50m or negedge rst_n)
        if(!rst_n) data_in_reg <= 64'd0;
        else if(data_en && o_upstream_ready) 
            data_in_reg <= data_in;

    // 状态机
    always@(posedge clk_50m or negedge rst_n)
        if(!rst_n) state <= IDLE;
        else case(state)
            IDLE: if(data_en) state <= WRAM1;
            WRAM1: if(ram1_wr_addr == CNT_MAX) state <= WRAM2_RRAM1;
            WRAM2_RRAM1: if(ram2_wr_addr == CNT_MAX && ram1_rd_done) state <= WRAM1_RRAM2;
            WRAM1_RRAM2: if(ram1_wr_addr == CNT_MAX && ram2_rd_done) state <= WRAM2_RRAM1;
            default: state <= IDLE;
        endcase

    // Ready & Write Enable
    always @(*) begin
        case(state)
            IDLE:        o_upstream_ready = 1'b1; 
            WRAM1:       o_upstream_ready = (ram1_wr_addr < CNT_MAX); 
            WRAM1_RRAM2: o_upstream_ready = (ram1_wr_addr < CNT_MAX);
            WRAM2_RRAM1: o_upstream_ready = (ram2_wr_addr < CNT_MAX);
            default:     o_upstream_ready = 1'b0;
        endcase
    end

    always @(*) begin
        ram1_wr_en = 0;
        ram2_wr_en = 0;
        if(data_en && o_upstream_ready) begin
            case(state)
                WRAM1, WRAM1_RRAM2: ram1_wr_en = 1;
                WRAM2_RRAM1:        ram2_wr_en = 1;
            endcase
        end
    end

    // 写地址
    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) ram1_wr_addr <= 0;
        else if(state == WRAM2_RRAM1) ram1_wr_addr <= 0;
        else if(ram1_wr_en && ram1_wr_addr < CNT_MAX) 
            ram1_wr_addr <= ram1_wr_addr + 1'b1;
    end
    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) ram2_wr_addr <= 0;
        else if(state == WRAM1_RRAM2 || state == WRAM1) ram2_wr_addr <= 0;
        else if(ram2_wr_en && ram2_wr_addr < CNT_MAX) 
            ram2_wr_addr <= ram2_wr_addr + 1'b1;
    end

    // 读控制
    always @(*) begin
        ram1_rd_en = (state == WRAM2_RRAM1) && !ram1_rd_done;
        ram2_rd_en = (state == WRAM1_RRAM2) && !ram2_rd_done;
    end

    // 读地址
    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
        else if(state != WRAM2_RRAM1) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
        else if(ram1_rd_en && i_downstream_ready) begin 
            if(ram1_rd_addr == CNT_MAX) ram1_rd_done <= 1;
            else ram1_rd_addr <= ram1_rd_addr + 1'b1;
        end
    end
    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
        else if(state != WRAM1_RRAM2) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
        else if(ram2_rd_en && i_downstream_ready) begin 
            if(ram2_rd_addr == CNT_MAX) ram2_rd_done <= 1;
            else ram2_rd_addr <= ram2_rd_addr + 1'b1;
        end
    end

    // -----------------------------------------------------------------
    // 输出逻辑修正：Valid 和 Data 均使用寄存器输出，保证严格对齐
    // -----------------------------------------------------------------
reg valid_reg;   
    // 1. Valid 信号打拍
    always @(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) 
            valid_reg <= 0;
        else if(i_downstream_ready)
            valid_reg <= (ram1_rd_en || ram2_rd_en);
    end
assign o_data_valid = valid_reg && (ram1_rd_en || ram2_rd_en);
    // 2. Data 信号打拍
    always @(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) 
            data_out <= 64'd0;
        else if(i_downstream_ready) begin
            if(ram1_rd_en)      data_out <= ram1_rd_data;
            else if(ram2_rd_en) data_out <= ram2_rd_data;
        end
    end


endmodule






`timescale 1ns / 1ps
module ram_ctrl1
(
    input  wire        clk_50m ,
    input  wire        rst_n ,
    
    // RAM 数据通路 (保持不变)
    input  wire [63:0] ram1_rd_data, 
    input  wire [63:0] ram2_rd_data, 
    output wire [63:0] ram1_wr_data, 
    output wire [63:0] ram2_wr_data, 
    
    // RAM 控制 (保持不变)
    output reg         ram1_wr_en , 
    output reg         ram1_rd_en , 
    output reg  [6:0]  ram1_wr_addr, // 7位地址，0~64
    output reg  [5:0]  ram1_rd_addr, 
    
    output reg         ram2_wr_en , 
    output reg         ram2_rd_en , 
    output reg  [6:0]  ram2_wr_addr, 
    output reg  [5:0]  ram2_rd_addr, 
    
    // 上游接口
    input  wire        data_en ,       
    input  wire        i_tlast,        // 【新增】仅增加这个接口
    input  wire [63:0] data_in ,       
    output reg         o_upstream_ready, 
    
    // 下游接口 (保持不变)
    input  wire        i_downstream_ready, 
    output wire        o_data_valid,    
    output reg  [63:0] data_out            
);

    // 状态定义 (保持不变)
    localparam   IDLE        = 4'b0001, 
                 WRAM1       = 4'b0010, 
                 WRAM2_RRAM1 = 4'b0100, 
                 WRAM1_RRAM2 = 4'b1000; 

    // 计数器参数 (保持不变)
    localparam CNT_WR_MAX = 7'd64; 
    localparam CNT_RD_MAX = 6'd63; 

    reg [3:0] state ; 
    reg ram1_rd_done;
    reg ram2_rd_done;
    
    // 【新增】用于记录实际存了多少个数据 (解决不满64个的问题)
    reg [6:0] ram1_stored_len; 
    reg [6:0] ram2_stored_len;

    // ============================================================
    // 1. 输入打拍逻辑 (逻辑完全未变，仅增加 tlast 跟随打拍)
    // ============================================================
    reg [63:0] data_in_d;
    reg        data_en_d;
    reg        tlast_d; // 【新增】让 tlast 也延迟一拍，与 data 对齐

    always @(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin
            data_in_d <= 0;
            data_en_d <= 0;
            tlast_d   <= 0;
        end
        else if(o_upstream_ready) begin
            // 只有 Ready 时才采入数据，逻辑未变
            data_in_d <= data_in;
            data_en_d <= data_en;
            tlast_d   <= i_tlast; // 【新增】
        end
        else begin
            // Ready 拉低后停止采入 Valid，防止溢出，逻辑未变
            data_en_d <= 0;
            tlast_d   <= 0;
        end
    end

    // 写数据源 (保持不变)
    assign ram1_wr_data = (ram1_wr_en) ? data_in_d : 64'd0;
    assign ram2_wr_data = (ram2_wr_en) ? data_in_d : 64'd0;

    // ============================================================
    // 2. Ready 信号逻辑 (逻辑完全未变)
    // ============================================================
    // 依然是在写到 63 时拉低 Ready，留一个位置给寄存器里的数据
    always @(*) begin
        case(state)
            IDLE:        o_upstream_ready = 1'b1; 
            
            // 下面这几行完全没动，保证了之前的时序稳定性
            WRAM1:       o_upstream_ready = (ram1_wr_addr < (CNT_WR_MAX - 1)); 
            WRAM1_RRAM2: o_upstream_ready = (ram1_wr_addr < (CNT_WR_MAX - 1));
            WRAM2_RRAM1: o_upstream_ready = (ram2_wr_addr < (CNT_WR_MAX - 1));
            
            default:     o_upstream_ready = 1'b0;
        endcase
    end

    // ============================================================
    // 3. 写使能逻辑 (逻辑完全未变)
    // ============================================================
    always @(*) begin
        ram1_wr_en = 0;
        ram2_wr_en = 0;
        if(data_en_d) begin
            case(state)
                WRAM1, WRAM1_RRAM2: ram1_wr_en = 1;
                WRAM2_RRAM1:        ram2_wr_en = 1;
            endcase
        end
    end

    // ============================================================
    // 4. 状态机 (仅增加 || tlast 判断，原有的满跳转逻辑未变)
    // ============================================================
    always@(posedge clk_50m or negedge rst_n)
        if(!rst_n) state <= IDLE;
        else case(state)
            IDLE: if(data_en) state <= WRAM1;
            
            // 原逻辑：ram1_wr_addr == CNT_WR_MAX (写满64个跳转)
            // 新逻辑：或者 (正在写 && 是最后一个) 也跳转
            WRAM1: if(ram1_wr_addr == CNT_WR_MAX || (ram1_wr_en && tlast_d)) 
                       state <= WRAM2_RRAM1;
            
            WRAM2_RRAM1: if((ram2_wr_addr == CNT_WR_MAX || (ram2_wr_en && tlast_d)) && ram1_rd_done) 
                       state <= WRAM1_RRAM2;
            
            WRAM1_RRAM2: if((ram1_wr_addr == CNT_WR_MAX || (ram1_wr_en && tlast_d)) && ram2_rd_done) 
                       state <= WRAM2_RRAM1;
                       
            default: state <= IDLE;
        endcase

    // ============================================================
    // 5. 写地址逻辑 (逻辑未变，增加了 stored_len 记录)
    // ============================================================
    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram1_wr_addr <= 0; ram1_stored_len <= CNT_WR_MAX; end
        else if(state == WRAM2_RRAM1) begin 
            ram1_wr_addr <= 0; 
        end
        else if(ram1_wr_en && ram1_wr_addr < CNT_WR_MAX) begin
            ram1_wr_addr <= ram1_wr_addr + 1'b1;
            
            // 【新增】如果是 TLAST，记录下当前写了多少个 (比如 4)
            // 如果不是 TLAST，就默认长度是最大值 (64)
            // 这样不影响正常的 64 个满传输
            if(tlast_d) ram1_stored_len <= ram1_wr_addr + 1'b1;
            else        ram1_stored_len <= CNT_WR_MAX;
        end
    end

    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram2_wr_addr <= 0; ram2_stored_len <= CNT_WR_MAX; end
        else if(state == WRAM1_RRAM2 || state == WRAM1) begin 
            ram2_wr_addr <= 0; 
        end
        else if(ram2_wr_en && ram2_wr_addr < CNT_WR_MAX) begin
            ram2_wr_addr <= ram2_wr_addr + 1'b1;
            
            // 【新增】同上
            if(tlast_d) ram2_stored_len <= ram2_wr_addr + 1'b1;
            else        ram2_stored_len <= CNT_WR_MAX;
        end
    end

    // ============================================================
    // 6. 读控制 (逻辑微调：从固定读 64 改为读 stored_len)
    // ============================================================
    always @(*) begin
        ram1_rd_en = (state == WRAM2_RRAM1) && !ram1_rd_done;
        ram2_rd_en = (state == WRAM1_RRAM2) && !ram2_rd_done;
    end

    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
        else if(state != WRAM2_RRAM1) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
        else if(ram1_rd_en && i_downstream_ready) begin 
            // 原逻辑：if (ram1_rd_addr == 63)
            // 新逻辑：if (ram1_rd_addr == stored_len - 1)
            // 注意：正常情况下 stored_len 就是 64，所以 64-1=63，逻辑完全一致！
            if(ram1_rd_addr == (ram1_stored_len - 1'b1)) ram1_rd_done <= 1;
            else ram1_rd_addr <= ram1_rd_addr + 1'b1;
        end
    end

    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
        else if(state != WRAM1_RRAM2) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
        else if(ram2_rd_en && i_downstream_ready) begin 
            // 同上
            if(ram2_rd_addr == (ram2_stored_len - 1'b1)) ram2_rd_done <= 1;
            else ram2_rd_addr <= ram2_rd_addr + 1'b1;
        end
    end

    // ============================================================
    // 7. 输出逻辑 (完全未变)
    // ============================================================
    reg valid_reg;   
    always @(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) 
            valid_reg <= 0;
        else if(i_downstream_ready)
            valid_reg <= (ram1_rd_en || ram2_rd_en);
    end
    assign o_data_valid = valid_reg && (ram1_rd_en || ram2_rd_en);

    always @(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) 
            data_out <= 64'd0;
        else if(i_downstream_ready) begin
            if(ram1_rd_en)      data_out <= ram1_rd_data;
            else if(ram2_rd_en) data_out <= ram2_rd_data;
        end
    end

endmodule
