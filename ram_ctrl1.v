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