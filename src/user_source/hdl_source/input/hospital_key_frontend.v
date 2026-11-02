`timescale 1ns/1ps
// Production input stage. Shared by the top-level diagnostic and unit tests.
// key_n[i]: independent pull-up input, 0 while pressed.
// Default: 25MHz / 500000 consecutive samples = 20ms (plus CDC latency).
// rst: active high, async assert; caller must synchronize its deassertion.
// All outputs are in clk domain. press/release are one-clock bitmasks,
// not an event queue: the consumer must capture ALL set bits each cycle.
// At startup, a key must first be stably released to become armed. A held
// boot/reset key is visible in pressed but generates neither a press nor
// a release event until it has been released and pressed again.
module hospital_key_frontend #(
    parameter integer KEY_COUNT = 8,
    parameter integer DEBOUNCE_CYCLES = 500000
)(
    input wire clk,
    input wire rst,
    input wire [KEY_COUNT-1:0] key_n,
    output reg [KEY_COUNT-1:0] pressed,
    output reg [KEY_COUNT-1:0] press_pulse,
    output reg [KEY_COUNT-1:0] release_pulse,
    output reg [KEY_COUNT-1:0] armed
);
    localparam integer COUNT_WIDTH = (DEBOUNCE_CYCLES < 2) ? 1 :
                                        $clog2(DEBOUNCE_CYCLES + 1);
    localparam [COUNT_WIDTH-1:0] LIMIT = DEBOUNCE_CYCLES;
    reg [KEY_COUNT-1:0] sync0; /* synthesis keep */
    reg [KEY_COUNT-1:0] sync1; /* synthesis keep */
    reg [1:0] sync_valid;

    // Do not count synchronizer reset values as a real released input.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync0 <= {KEY_COUNT{1'b1}};
            sync1 <= {KEY_COUNT{1'b1}};
            sync_valid <= 2'b00;
        end else begin
            sync0 <= key_n;
            sync1 <= sync0;
            sync_valid <= {sync_valid[0], 1'b1};
        end
    end

    genvar k;
    generate for (k = 0; k < KEY_COUNT; k = k + 1) begin : g_key
        reg last_sample;
        reg [COUNT_WIDTH-1:0] stable_count;
        always @(posedge clk or posedge rst) begin
            if (rst) begin
                last_sample <= 1'b1;
                stable_count <= 0;
                pressed[k] <= 1'b0;
                armed[k] <= 1'b0;
                press_pulse[k] <= 1'b0;
                release_pulse[k] <= 1'b0;
            end else begin
                press_pulse[k] <= 1'b0;
                release_pulse[k] <= 1'b0;
                if (sync_valid[1]) begin
                    last_sample <= sync1[k];
                    if (sync1[k] != last_sample)
                        stable_count <= 1;
                    else if (stable_count < LIMIT)
                        stable_count <= stable_count + 1'b1;

                    // Accept exactly after N consecutive real samples.
                    if ((DEBOUNCE_CYCLES == 1) ||
                        ((sync1[k] == last_sample) &&
                         (stable_count == LIMIT - 1'b1))) begin
                        if (sync1[k]) begin
                            release_pulse[k] <= armed[k] && pressed[k];
                            pressed[k] <= 1'b0;
                            armed[k] <= 1'b1;
                        end else begin
                            press_pulse[k] <= armed[k] && !pressed[k];
                            pressed[k] <= 1'b1;
                        end
                    end
                end
            end
        end
    end endgenerate

    // synthesis translate_off
    initial begin
        if (KEY_COUNT < 1 || DEBOUNCE_CYCLES < 1)
            $fatal(1, "KEY_COUNT and DEBOUNCE_CYCLES must be positive");
    end
    // synthesis translate_on
endmodule
