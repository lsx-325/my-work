module simple_dual_port_ram_dynamic #(parameter WIDTH=8, DEPTH=512)(
    input clk, input we, 
    input [$clog2(DEPTH)-1:0] wr_addr, rd_addr,
    input [WIDTH-1:0] din, output reg [WIDTH-1:0] dout
);
    (* ram_style = "block" *) reg [WIDTH-1:0] ram [0:DEPTH-1];
    
    // 初始化 RAM 以避免仿真不定态 (可选)
    integer i;
    initial begin
        for(i=0; i<DEPTH; i=i+1) ram[i] = 0;
    end

    always @(posedge clk) begin
        if (we) ram[wr_addr] <= din;
        dout <= ram[rd_addr]; // 读延迟 1 拍
    end
endmodule
