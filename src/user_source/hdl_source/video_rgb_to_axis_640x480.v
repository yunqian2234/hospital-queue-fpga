
module video_rgb_to_axis_640x480(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_vs,
    input  wire        I_de,
    input  wire [23:0] I_rgb,

    output reg         O_video_user,
    output reg         O_video_valid,
    output reg         O_video_last,
    output reg  [23:0] O_video_data
);

reg        S_vs_1d;
reg        S_de_1d;
reg        S_frame_arm;
reg [10:0] S_x_cnt;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_vs_1d       <= 1'b0;
        S_de_1d       <= 1'b0;
        S_frame_arm   <= 1'b1;
        S_x_cnt       <= 11'd0;
        O_video_user  <= 1'b0;
        O_video_valid <= 1'b0;
        O_video_last  <= 1'b0;
        O_video_data  <= 24'd0;
    end
    else begin
        S_vs_1d <= I_vs;
        S_de_1d <= I_de;

        O_video_user  <= 1'b0;
        O_video_valid <= I_de;
        O_video_last  <= 1'b0;
        O_video_data  <= I_rgb;

        // 任意一次 VS 跳变后，把“下一次 active video 的首像素”当成 SOF
        if (S_vs_1d != I_vs)
            S_frame_arm <= 1'b1;

        if (I_de) begin
            if (!S_de_1d) begin
                // 一行首像素
                S_x_cnt <= 11'd0;
                if (S_frame_arm) begin
                    O_video_user <= 1'b1;
                    S_frame_arm  <= 1'b0;
                end
            end
            else begin
                S_x_cnt <= S_x_cnt + 11'd1;
            end

            // 640x480 最后一个有效像素
            if (S_de_1d && S_x_cnt == 11'd638)
                O_video_last <= 1'b1;
        end
        else begin
            S_x_cnt <= 11'd0;
        end
    end
end

endmodule

// Observe the official timed HDMI input without changing a single pixel clock.
// E13 now means input not locked / active pixel rejected after acquisition.
// Ready may be low in blanking; this is normal and is never reported as a fault.
// Allow three complete input frame starts for the vendor's phase acquisition.
module hdmi_raster_monitor(
    input wire clk,rst,video_sof,video_valid,video_ready,video_locked,
    output reg fault
);
    reg [1:0] warmup_frames;
    always @(posedge clk or posedge rst) begin
        if(rst) begin warmup_frames<=0;fault<=0;end
        else begin
            if(video_sof && !(&warmup_frames)) warmup_frames<=warmup_frames+1'b1;
            if((&warmup_frames) && (!video_locked || (video_valid && !video_ready)))
                fault<=1;
        end
    end
endmodule
