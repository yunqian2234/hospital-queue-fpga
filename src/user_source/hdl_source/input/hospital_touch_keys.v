`timescale 1ns/1ps
// SEMANTIC_INPUT=1 (production): legacy HMI clicks are already confirmed;
// freeze card/number and use the core's request/result handshake. Physical keys
// pass through, page notifications do not submit. Mode 0 is retained solely for
// regression of the earlier seek-and-inject adapter, never enabled by the top.
module hospital_touch_keys #(
    parameter integer MAX_STEPS = 16,
    parameter integer SEMANTIC_INPUT = 0
)(
    input wire clk, rst,
    input wire cmd_valid,
    input wire [6:0] cmd, arg,
    input wire [2:0] selected_card,
    input wire [7:0] key_press_in,
    output wire [7:0] key_press_out,
    output wire busy,
    output reg [15:0] accepted_cmds,
    output reg [15:0] dropped_cmds,
    input wire [4:0] call_number,
    output reg request_valid,output reg [2:0] request_kind,request_card,
    output reg [4:0] request_number,input wire request_ready,
    input wire request_done,request_accepted,input wire [2:0] request_result,
    output reg command_rejected
);
    // Production mode: one click is an already confirmed frozen request.
    // Legacy mode remains only for old benches/interface compatibility; not in production.
    generate if(SEMANTIC_INPUT!=0) begin:g_semantic
        reg waiting;
        assign key_press_out=key_press_in;
        assign busy=request_valid || waiting;
        always @(posedge clk or posedge rst) begin
            if(rst) begin
                request_valid<=0;request_kind<=0;request_card<=0;request_number<=0;
                waiting<=0;accepted_cmds<=0;dropped_cmds<=0;command_rejected<=0;
            end else begin
                command_rejected<=0;
                if(request_valid && request_ready) begin request_valid<=0;waiting<=1;end
                if(request_done && waiting) waiting<=0;
                // cmd 4 page notice and cmd 5..8 check-in registration (hospital_registration) are not requests
                if(cmd_valid && cmd!=7'h04 && !(cmd>=7'd5 && cmd<=7'd8)) begin
                    if(busy || !((cmd==1 && arg<6) || ((cmd==2 || cmd==3) && arg==0))) begin
                        command_rejected<=1;
                        if(dropped_cmds!=16'hffff) dropped_cmds<=dropped_cmds+1'b1;
                    end else begin
                        request_valid<=1;request_kind<=cmd==1 ? 3'd3:cmd==2 ? 3'd2:3'd6;
                        request_card<=arg[2:0];request_number<=call_number;
                        if(accepted_cmds!=16'hffff) accepted_cmds<=accepted_cmds+1'b1;
                    end
                end
            end
        end
    end else begin:g_legacy
    always @* begin request_valid=1'b0 & rst;request_kind=0;request_card=0;request_number=0;command_rejected=0;end
    localparam [1:0] IDLE = 0, SEEK = 1, SETTLE = 2;
    localparam [6:0] CMD_CARD = 7'h01, CMD_REPLAY = 7'h02, CMD_TICKET = 7'h03, CMD_PAGE = 7'h04;
    reg [1:0] state;
    reg [2:0] target;
    reg [4:0] steps;
    reg [7:0] inject;
    assign key_press_out = key_press_in | inject;
    assign busy = state != IDLE;
    function [15:0] inc; input [15:0] v; inc = v == 16'hffff ? v : v + 1'b1; endfunction
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE; target <= 0; steps <= 0; inject <= 0;
            accepted_cmds <= 0; dropped_cmds <= 0;
        end else begin
            inject <= 0;
            if (cmd_valid && state != IDLE && cmd != CMD_PAGE) dropped_cmds <= inc(dropped_cmds);
            case (state)
                IDLE: if (cmd_valid) begin
                    if (cmd == CMD_CARD && arg <= 7'd5) begin
                        target <= arg[2:0]; steps <= 0; state <= SEEK;
                        accepted_cmds <= inc(accepted_cmds);
                    end else if (cmd == CMD_REPLAY && arg == 0) begin
                        inject <= 8'h40;
                        accepted_cmds <= inc(accepted_cmds);
                    end else if (cmd == CMD_TICKET && arg == 0) begin
                        inject <= 8'h80;
                        accepted_cmds <= inc(accepted_cmds);
                    end else if (cmd != CMD_PAGE) dropped_cmds <= inc(dropped_cmds);
                end
                SEEK: begin
                    if (selected_card == target) begin inject <= 8'h20; state <= IDLE; end
                    else if (steps == MAX_STEPS) begin dropped_cmds <= inc(dropped_cmds); state <= IDLE; end
                    else begin inject <= 8'h10; steps <= steps + 1'b1; state <= SETTLE; end
                end
                SETTLE: state <= SEEK;   // core registers the selection on the inject edge
                default: state <= IDLE;
            endcase
        end
    end
    end endgenerate
endmodule
