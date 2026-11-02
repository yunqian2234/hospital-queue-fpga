// 第8课：突发期间独占，读返回收齐或写收尾后才交接；读 FIFO 需求优先。
module media_sdram_arbiter(input clk,rst,ready,busy,refresh,
 input wr_request,rd_request,wr_done,rd_done,output wr_grant,rd_grant);
reg [1:0] owner;
assign rd_grant=owner==0 && ready && !busy && !refresh && rd_request;
assign wr_grant=owner==0 && ready && !busy && !refresh && !rd_request && wr_request;
always @(posedge clk or posedge rst) begin
 if(rst) owner<=0;
 else case(owner)
  0: if(rd_grant) owner<=1;else if(wr_grant) owner<=2;
  1: if(rd_done) owner<=0;
  2: if(wr_done) owner<=0;
  default:owner<=0;
 endcase
end
endmodule
