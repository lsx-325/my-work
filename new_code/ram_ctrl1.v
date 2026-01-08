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
    
    // ä¾ç„¶ä½¿ç”¨ 7 ä½å®½åœ°å€ï¼Œç¡®ä¿èƒ½è®¡æ•°åˆ? 64
    output reg  [6:0]  ram1_wr_addr, 
    output reg  [5:0]  ram1_rd_addr, 
    
    output reg         ram2_wr_en , 
    output reg         ram2_rd_en , 
    output reg  [6:0]  ram2_wr_addr, 
    output reg  [5:0]  ram2_rd_addr, 
    
    input  wire        data_en ,       
    input  wire [63:0] data_in ,       
    output reg         o_upstream_ready, 
    
    input  wire        i_downstream_ready, 
    output wire        o_data_valid,    
    output reg  [63:0] data_out            
);

    parameter   IDLE        = 4'b0001, 
                WRAM1       = 4'b0010, 
                WRAM2_RRAM1 = 4'b0100, 
                WRAM1_RRAM2 = 4'b1000; 

    // å†™è®¡æ•°å™¨æœ?å¤§å?? 64
    localparam CNT_WR_MAX = 7'd64; 
    localparam CNT_RD_MAX = 6'd63; 

    reg [3:0] state ; 
    reg ram1_rd_done;
    reg ram2_rd_done;

    // ============================================================
    // ã€å…³é”®ä¿®æ”?1ã€‘è¾“å…¥ä¿¡å·æ‰“æ‹? (Register Input)
    // è§£å†³ "data_in ä¸ç¨³å®?" çš„é—®é¢?
    // ============================================================
    reg [63:0] data_in_d;
    reg        data_en_d;

    always @(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin
            data_in_d <= 64'd0;
            data_en_d <= 1'b0;
        end
        else if(o_upstream_ready) begin
            // åªæœ‰å½? Ready ä¸ºé«˜æ—¶ï¼Œæ‰æ¥æ”¶æ•°æ®è¿›å¯„å­˜å™?
            data_in_d <= data_in;
            data_en_d <= data_en;
        end
        else begin
            // å¦‚æœ Ready æ‹‰ä½äº†ï¼Œåœæ­¢æ¥æ”¶æœ‰æ•ˆæ ‡å¿—ï¼ˆé˜²æ­¢æº¢å‡ºå†™å…¥ï¼‰
            data_en_d <= 1'b0;
        end
    end

    // ============================================================
    // ã€å…³é”®ä¿®æ”?2ã€‘å†™æ•°æ®ä½¿ç”¨æ‰“æ‹åçš„ä¿¡å·
    // ============================================================
    // å†™æ•°æ®æºæ”¹ä¸º data_in_d (å¯„å­˜å™¨è¾“å‡ºï¼Œæ—¶åºç¨³å®š)
    assign ram1_wr_data = (ram1_wr_en) ? data_in_d : 64'd0;
    assign ram2_wr_data = (ram2_wr_en) ? data_in_d : 64'd0;

    // ============================================================
    // ã€å…³é”®ä¿®æ”?3ã€‘Ready ä¿¡å·é€»è¾‘ (æå‰ä¸?æ‹å…³é—?)
    // ============================================================
    always @(*) begin
        case(state)
            IDLE:        o_upstream_ready = 1'b1; 
            
            // æ³¨æ„ï¼šè¿™é‡Œæ”¹æˆäº† < 63 (CNT_WR_MAX - 1)
            // ä¸ºä»€ä¹ˆï¼Ÿå› ä¸ºæˆ‘ä»¬åŠ äº†å¯„å­˜å™¨å»¶è¿Ÿã??
            // å½? ram_wr_addr ç­‰äº 63 æ—¶ï¼Œè¯´æ˜ RAM é‡Œå·²ç»å†™äº? 63 ä¸ªæ•°ã€?
            // ä½†æ­¤æ—¶å¯„å­˜å™¨ data_in_d é‡Œå¯èƒ½æ­£å­˜ç€ç¬? 64 ä¸ªæ•°ç­‰å¾…å†™å…¥ã€?
            // æ‰?ä»¥å¿…é¡»ç°åœ¨å°±æ‹‰ä½ Readyï¼Œé˜»æ­¢ç¬¬ 65 ä¸ªæ•°è¿›å…¥å¯„å­˜å™¨ã??
            WRAM1:       o_upstream_ready = (ram1_wr_addr < (CNT_WR_MAX - 1'b1)); 
            WRAM1_RRAM2: o_upstream_ready = (ram1_wr_addr < (CNT_WR_MAX - 1'b1));
            WRAM2_RRAM1: o_upstream_ready = (ram2_wr_addr < (CNT_WR_MAX - 1'b1));
            
            default:     o_upstream_ready = 1'b0;
        endcase
    end

    // ============================================================
    // å†™ä½¿èƒ½é?»è¾‘ (ä½¿ç”¨æ‰“æ‹åçš„ Valid)
    // ============================================================
    always @(*) begin
        ram1_wr_en = 0;
        ram2_wr_en = 0;
        // ä½¿ç”¨ data_en_d (å»¶è¿Ÿåçš„ä½¿èƒ½)
        // æ³¨æ„ï¼šè¿™é‡Œä¸éœ?è¦å†åˆ¤æ–­ Readyï¼Œå› ä¸? data_en_d çš„ç”Ÿæˆå·²ç»å— Ready æ§åˆ¶äº?
        if(data_en_d) begin
            case(state)
                WRAM1, WRAM1_RRAM2: ram1_wr_en = 1;
                WRAM2_RRAM1:        ram2_wr_en = 1;
            endcase
        end
    end

    // ============================================================
    // çŠ¶æ?æœº (ä¿æŒ 7 ä½è®¡æ•°å™¨çš„è·³è½¬é?»è¾‘)
    // ============================================================
    always@(posedge clk_50m or negedge rst_n)
        if(!rst_n) state <= IDLE;
        else case(state)
            IDLE: if(data_en) state <= WRAM1; // è¿™é‡Œå¯ä»¥ç”? data_en æˆ–è?? data_en_d å¯åŠ¨ï¼Œå½±å“ä¸å¤?
            
            // åªè¦åœ°å€åˆ°äº† 64ï¼Œè¯´æ˜ç¬¬ 64 ä¸ªæ•°ï¼ˆå­˜åœ¨å¯„å­˜å™¨é‡Œçš„é‚£ä¸ªï¼‰å·²ç»å†™è¿›å»äº?
            WRAM1: if(ram1_wr_addr == CNT_WR_MAX) 
                       state <= WRAM2_RRAM1;
            
            WRAM2_RRAM1: if(ram2_wr_addr == CNT_WR_MAX && ram1_rd_done) 
                       state <= WRAM1_RRAM2;
            
            WRAM1_RRAM2: if(ram1_wr_addr == CNT_WR_MAX && ram2_rd_done) 
                       state <= WRAM2_RRAM1;
                       
            default: state <= IDLE;
        endcase

    // ============================================================
    // å†™åœ°å?é€»è¾‘ (7ä½è®¡æ•°å™¨ï¼?0~64)
    // ============================================================
    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) ram1_wr_addr <= 0;
        else if(state == WRAM2_RRAM1) ram1_wr_addr <= 0;
        else if(ram1_wr_en && ram1_wr_addr < CNT_WR_MAX) 
            ram1_wr_addr <= ram1_wr_addr + 1'b1;
    end

    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) ram2_wr_addr <= 0;
        else if(state == WRAM1_RRAM2 || state == WRAM1) ram2_wr_addr <= 0;
        else if(ram2_wr_en && ram2_wr_addr < CNT_WR_MAX) 
            ram2_wr_addr <= ram2_wr_addr + 1'b1;
    end

    // ============================================================
    // è¯»æ§åˆ¶ä¸è¾“å‡º (ä¿æŒåŸæ ·)
    // ============================================================
    always @(*) begin
        ram1_rd_en = (state == WRAM2_RRAM1) && !ram1_rd_done;
        ram2_rd_en = (state == WRAM1_RRAM2) && !ram2_rd_done;
    end

    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
        else if(state != WRAM2_RRAM1) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
        else if(ram1_rd_en && i_downstream_ready) begin 
            if(ram1_rd_addr == CNT_RD_MAX) ram1_rd_done <= 1;
            else ram1_rd_addr <= ram1_rd_addr + 1'b1;
        end
    end

    always@(posedge clk_50m or negedge rst_n) begin
        if(!rst_n) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
        else if(state != WRAM1_RRAM2) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
        else if(ram2_rd_en && i_downstream_ready) begin 
            if(ram2_rd_addr == CNT_RD_MAX) ram2_rd_done <= 1;
            else ram2_rd_addr <= ram2_rd_addr + 1'b1;
        end
    end

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
//`timescale 1ns / 1ps
//module ram_ctrl1
//(
//    input  wire        clk_50m ,
//    input  wire        rst_n ,
    
//    input  wire [63:0] ram1_rd_data, 
//    input  wire [63:0] ram2_rd_data, 
//    output wire [63:0] ram1_wr_data, 
//    output wire [63:0] ram2_wr_data, 
    
//    output reg         ram1_wr_en , 
//    output reg         ram1_rd_en , 
    
//    output reg  [6:0]  ram1_wr_addr, 
//    output reg  [5:0]  ram1_rd_addr, 
    
//    output reg         ram2_wr_en , 
//    output reg         ram2_rd_en , 
//    output reg  [6:0]  ram2_wr_addr, 
//    output reg  [5:0]  ram2_rd_addr, 
    
//    input  wire        data_en ,       
//    input  wire [63:0] data_in ,     
//    input  wire        i_data_last,     // ÊäÈëÊı¾İµÄ½áÊø±êÖ¾  
//    output reg         o_upstream_ready, 
    
//    input  wire        i_downstream_ready, 
//    output wire        o_data_valid,    
//    output reg         o_data_last,     // Êä³öÊı¾İµÄ½áÊø±êÖ¾
//    output reg  [63:0] data_out            
//);

//    parameter   IDLE        = 4'b0001, 
//                WRAM1       = 4'b0010, 
//                WRAM2_RRAM1 = 4'b0100, 
//                WRAM1_RRAM2 = 4'b1000; 

//    localparam CNT_WR_MAX = 7'd64; 

//    reg [3:0] state ; 
//    reg ram1_rd_done;
//    reg ram2_rd_done;
    
//    // ¼ÇÂ¼Ã¿¿é RAM Êµ¼ÊĞ´ÈëµÄÊı¾İ³¤¶È (1-64)
//    reg [6:0] ram1_len;
//    reg [6:0] ram2_len;

//    // ============================================================
//    // 1. ÊäÈëĞÅºÅ´òÅÄ
//    // ============================================================
//    reg [63:0] data_in_d;
//    reg        data_en_d;
//    reg        i_data_last_d;

//    always @(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) begin
//            data_in_d <= 64'd0;
//            data_en_d <= 1'b0;
//            i_data_last_d <= 1'b0;
//        end
//        else if(o_upstream_ready) begin
//            data_in_d <= data_in;
//            data_en_d <= data_en;
//            i_data_last_d <= i_data_last;
//        end
//        else begin
//            data_en_d <= 1'b0;
//            i_data_last_d <= 1'b0;
//        end
//    end

//    assign ram1_wr_data = (ram1_wr_en) ? data_in_d : 64'd0;
//    assign ram2_wr_data = (ram2_wr_en) ? data_in_d : 64'd0;

//    // ============================================================
//    // 2. Ready ĞÅºÅÂß¼­ (ÌáÇ°Ò»ÅÄ¹ØÃÅ)
//    // ============================================================
//    always @(*) begin
//        case(state)
//            IDLE:        o_upstream_ready = 1'b1; 
//            WRAM1:       o_upstream_ready = (ram1_wr_addr < (CNT_WR_MAX - 1'b1)); 
//            WRAM1_RRAM2: o_upstream_ready = (ram1_wr_addr < (CNT_WR_MAX - 1'b1));
//            WRAM2_RRAM1: o_upstream_ready = (ram2_wr_addr < (CNT_WR_MAX - 1'b1));
//            default:     o_upstream_ready = 1'b0;
//        endcase
//    end

//    // ============================================================
//    // 3. ×´Ì¬»ú (¼ÓÈë¶ÁÍêÅĞ¶¨Óë³¤¶È²¶»ñ)
//    // ============================================================
//    always@(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) begin
//            state <= IDLE;
//            ram1_len <= 0;
//            ram2_len <= 0;
//        end
//        else case(state)
//            IDLE: if(data_en) state <= WRAM1; 
            
//            WRAM1: begin
//                // Èç¹ûµØÖ·µ½ 64 »òÕßÊÕµ½ last£¬Ìø×ª²¢¼ÇÂ¼³¤¶È
//                if(ram1_wr_en && (ram1_wr_addr == CNT_WR_MAX - 1'b1 || i_data_last_d)) begin
//                       state <= WRAM2_RRAM1;
//                       ram1_len <= ram1_wr_addr + 1'b1; 
//                end
//            end    

//            WRAM2_RRAM1: begin 
//                // Ìõ¼ş£º±¾ÂÖĞ´Âú(»òÊÕµ½last) ÇÒ ÉÏÒ»ÂÖÊı¾İÒÑ¾­¶ÁÍê
//                if(ram2_wr_en && (ram2_wr_addr == CNT_WR_MAX - 1'b1 || i_data_last_d)) begin
//                    if(ram1_rd_done) begin // ÎÕÊÖ±£»¤£¬·ÀÖ¹¸²¸ÇÎ´¶Á³öµÄ RAM1
//                        state <= WRAM1_RRAM2;
//                        ram2_len <= ram2_wr_addr + 1'b1;
//                    end
//                end
//            end

//            WRAM1_RRAM2: begin 
//                if(ram1_wr_en && (ram1_wr_addr == CNT_WR_MAX - 1'b1 || i_data_last_d)) begin
//                    if(ram2_rd_done) begin // ÎÕÊÖ±£»¤£¬·ÀÖ¹¸²¸ÇÎ´¶Á³öµÄ RAM2
//                        state <= WRAM2_RRAM1;
//                        ram1_len <= ram1_wr_addr + 1'b1;
//                    end
//                end
//            end           
//            default: state <= IDLE;
//        endcase
//    end

//    // ============================================================
//    // 4. Ğ´µØÖ·Âß¼­
//    // ============================================================
//    always@(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) ram1_wr_addr <= 0;
//        else if(state == WRAM2_RRAM1) ram1_wr_addr <= 0;
//        else if(ram1_wr_en && ram1_wr_addr < CNT_WR_MAX) 
//            ram1_wr_addr <= ram1_wr_addr + 1'b1;
//    end

//    always@(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) ram2_wr_addr <= 0;
//        else if(state == WRAM1_RRAM2 || state == WRAM1) ram2_wr_addr <= 0;
//        else if(ram2_wr_en && ram2_wr_addr < CNT_WR_MAX) 
//            ram2_wr_addr <= ram2_wr_addr + 1'b1;
//    end

//    // ============================================================
//    // 5. ¶Á¿ØÖÆÂß¼­ (ĞŞÕı¶ÁÖÕÖ¹ÅĞ¶¨)
//    // ============================================================
//    always @(*) begin
//        ram1_wr_en = (data_en_d && (state == WRAM1 || state == WRAM1_RRAM2));
//        ram2_wr_en = (data_en_d && (state == WRAM2_RRAM1));
//        ram1_rd_en = (state == WRAM2_RRAM1) && !ram1_rd_done;
//        ram2_rd_en = (state == WRAM1_RRAM2) && !ram2_rd_done;
//    end

//    always@(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
//        else if(state != WRAM2_RRAM1) begin ram1_rd_addr <= 0; ram1_rd_done <= 0; end
//        else if(ram1_rd_en && i_downstream_ready) begin 
//            // ĞŞÕı£º¶Ô±ÈÊµ¼Ê³¤¶È ram1_len£¬¶ø²»ÊÇËÀµÈ 63
//            if(ram1_rd_addr == ram1_len[5:0] - 1'b1) 
//                ram1_rd_done <= 1;
//            else 
//                ram1_rd_addr <= ram1_rd_addr + 1'b1;
//        end
//    end

//    always@(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
//        else if(state != WRAM1_RRAM2) begin ram2_rd_addr <= 0; ram2_rd_done <= 0; end
//        else if(ram2_rd_en && i_downstream_ready) begin 
//            if(ram2_rd_addr == ram2_len[5:0] - 1'b1) 
//                ram2_rd_done <= 1;
//            else 
//                ram2_rd_addr <= ram2_rd_addr + 1'b1;
//        end
//    end

//    // ============================================================
//    // 6. Êä³ö Valid/Last/Data (ÈıÕß¶ÔÆë)
//    // ============================================================
//    reg valid_reg;   
//    always @(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) begin
//            valid_reg <= 0;
//            o_data_last <= 0;
//        end
//        else if(i_downstream_ready) begin
//            valid_reg   <= (ram1_rd_en || ram2_rd_en);
//            // Last Óë Valid Í¬²½´òÅÄ²úÉú
//            o_data_last <= (ram1_rd_en && (ram1_rd_addr == ram1_len[5:0] - 1'b1)) || 
//                           (ram2_rd_en && (ram2_rd_addr == ram2_len[5:0] - 1'b1));
//        end
//    end
//    assign o_data_valid = valid_reg;

//    always @(posedge clk_50m or negedge rst_n) begin
//        if(!rst_n) 
//            data_out <= 64'd0;
//        else if(i_downstream_ready) begin
//            if(ram1_rd_en)      data_out <= ram1_rd_data;
//            else if(ram2_rd_en) data_out <= ram2_rd_data;
//        end
//    end

//endmodule