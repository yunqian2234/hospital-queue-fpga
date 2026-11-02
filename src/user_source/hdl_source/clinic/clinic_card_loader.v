`timescale 1ns/1ps
// 10/23 诊室板：开机从 TF 卡读 CARD1.BMP～CARD6.BMP（120×90、256 色调色板 BMP）到片上存储。
//
// Sector interface = sd_card_top (the top level owns sd_card_top and its local reset, like the
// hall board's sd_card_bmp). The rest is the hall's chain reused unchanged where possible:
//   sd_sector_adapter (one sector buffered, then replayed)        - shared file, unchanged
//   clinic_card_scanner (FAT32 mount, CARD1..6 in the root dir)    - clinic copy of the scanner
//   fat32_file_streamer (cluster chain -> byte stream)             - shared file, unchanged
//   clinic_bmp8_decode (below: header checks, palette, pixels)     - new
// Everything runs in video_clk (25 MHz); SPI is 390 kHz during init, then 6.25 MHz.
//
// Policy: no card / card not ready -> retry the SD init every INIT_WAIT_MS (hot insertion works);
// mount or directory failure -> retry after RETRY_MS; a CARDn.BMP that is missing or malformed
// is tried once and that card falls back to text on the screen. A card that has been loaded is
// never cleared; after an SD error only the cards not yet loaded are read again.
// While busy=1 the store's port A belongs to the loader (the zoom then uses the text fallback).
module clinic_card_loader #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer INIT_WAIT_MS = 2000,
    parameter integer RETRY_MS = 3000,
    parameter integer SD_TIMEOUT_MS = 500
)(
    input wire clk, rst,
    // sd_card_top sector interface
    input wire sd_init_done,
    output wire sd_read, output wire [31:0] sd_addr,
    input wire [7:0] sd_data, input wire sd_valid, sd_end,
    output reg sd_reset_req,             // one-clock request to re-initialise the SD card
    // results
    output reg [5:0] card_ready,
    output reg busy,
    output reg [3:0] status,             // 0 waiting for card, 1 scanning, 2 loading, 3 done, 4 retry
    // card store write port
    output wire pix_we, output wire [15:0] pix_waddr, output wire [7:0] pix_wdata,
    output wire pal_we, output wire [10:0] pal_waddr, output wire [23:0] pal_wdata
);
    localparam [31:0] INIT_LIMIT = (CLK_HZ / 1000) * INIT_WAIT_MS;
    localparam [31:0] RETRY_LIMIT = (CLK_HZ / 1000) * RETRY_MS;
    localparam S_WAIT_INIT = 0, S_SCAN = 1, S_SCAN_WAIT = 2, S_PICK = 3, S_LOAD = 4, S_LOAD_WAIT = 5,
               S_DONE = 6, S_RETRY = 7, S_DRAIN = 8;
    reg [3:0] state;
    reg [31:0] timer;
    reg [5:0] attempted;
    reg [2:0] slot;
    wire media_rst = rst || !sd_init_done;

    // ---------------- sector adapter + two clients (never active at the same time) ----------------
    wire adapter_ready, sector_valid, sector_done, sector_error, adapter_reset_req;
    wire [7:0] sector_data;
    wire [8:0] sector_index;
    wire scan_req, file_req, file_consume;
    wire [31:0] scan_lba, file_lba;
    wire scan_phase = (state == S_SCAN || state == S_SCAN_WAIT);
    wire request = scan_phase ? scan_req : file_req;
    wire grant = request && adapter_ready;
    sd_sector_adapter #(.CLK_FREQ_HZ(CLK_HZ), .TIMEOUT_MS(SD_TIMEOUT_MS)) u_sector(
        .clk(clk), .rst(rst), .media_ready(sd_init_done), .request(request),
        .request_lba(scan_phase ? scan_lba : file_lba), .request_ready(adapter_ready),
        .valid(sector_valid), .data(sector_data), .byte_index(sector_index),
        .consume(scan_phase ? 1'b1 : file_consume), .done(sector_done), .error(sector_error),
        .reset_req(adapter_reset_req),
        .sd_read(sd_read), .sd_addr(sd_addr), .sd_data(sd_data), .sd_valid(sd_valid), .sd_end(sd_end));

    reg scan_start;
    wire mounted, scan_done, scan_failed;
    wire [5:0] valid_mask;
    wire [191:0] clusters, sizes;
    wire [31:0] fat_lba, data_lba, max_cluster;
    wire [7:0] spc;
    wire [3:0] shift_value, scan_error;
    clinic_card_scanner #(.MAX_FILE_BYTES(32'd65536)) u_scan(
        .clk(clk), .rst(media_rst), .start(scan_start), .mounted(mounted), .scan_done(scan_done),
        .failed(scan_failed), .found(), .error_code(scan_error), .valid_mask(valid_mask),
        .file_clusters(clusters), .file_sizes(sizes), .fat_lba(fat_lba), .data_lba(data_lba),
        .max_cluster(max_cluster), .sectors_per_cluster(spc), .cluster_shift(shift_value),
        .request(scan_req), .request_lba(scan_lba), .grant(grant && scan_phase),
        .sector_valid(sector_valid && scan_phase), .sector_data(sector_data), .sector_index(sector_index),
        .sector_done(sector_done && scan_phase), .sector_error(sector_error),
        .audio_found(), .audio_invalid(), .audio_cluster(), .audio_size(),
        .voice_found(), .voice_invalid(), .voice_cluster(), .voice_size());

    reg file_start, file_abort;
    wire file_busy, file_done, file_failed, file_valid;
    wire [7:0] file_data;
    reg [31:0] file_size;
    fat32_file_streamer #(.MAX_FILE_BYTES(32'd65536)) u_file(
        .clk(clk), .rst(media_rst), .start(file_start), .abort(file_abort),
        .first_cluster(clusters[slot*32 +: 32]), .file_size(file_size), .fat_lba(fat_lba), .data_lba(data_lba),
        .max_cluster(max_cluster), .sectors_per_cluster(spc), .cluster_shift(shift_value),
        .busy(file_busy), .done(file_done), .failed(file_failed),
        .request(file_req), .request_lba(file_lba), .grant(grant && !scan_phase),
        .sector_valid(sector_valid && !scan_phase), .sector_data(sector_data), .sector_index(sector_index),
        .sector_done(sector_done && !scan_phase), .sector_error(sector_error), .sector_consume(file_consume),
        .file_valid(file_valid), .file_data(file_data), .file_ready(1'b1));

    wire dec_done, dec_ok, dec_bad_header;
    clinic_bmp8_decode u_dec(
        .clk(clk), .rst(media_rst), .start(file_start), .card(slot), .file_size(file_size[16:0]),
        .byte_valid(file_valid), .byte_data(file_data), .stream_done(file_done), .stream_failed(file_failed),
        .done(dec_done), .ok(dec_ok), .bad_header(dec_bad_header),
        .pix_we(pix_we), .pix_waddr(pix_waddr), .pix_wdata(pix_wdata),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata));

    // first card that was found, is not loaded and has not been tried in this mount
    wire [5:0] todo = valid_mask & ~card_ready & ~attempted;
    wire [2:0] first = todo[0] ? 3'd0 : todo[1] ? 3'd1 : todo[2] ? 3'd2 :
                       todo[3] ? 3'd3 : todo[4] ? 3'd4 : 3'd5;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_WAIT_INIT; timer <= 0; attempted <= 0; slot <= 0; card_ready <= 0; busy <= 0;
            status <= 0; scan_start <= 0; file_start <= 0; file_abort <= 0; file_size <= 0; sd_reset_req <= 0;
        end else begin
            scan_start <= 0; file_start <= 0; sd_reset_req <= 0;
            if (adapter_reset_req) sd_reset_req <= 1'b1;   // read timeout: the top re-initialises the card
            case (state)
                S_WAIT_INIT: begin
                    status <= 0; busy <= 0; file_abort <= 0;
                    if (sd_init_done) begin timer <= 0; state <= S_SCAN; end
                    else if (timer >= INIT_LIMIT - 1) begin timer <= 0; sd_reset_req <= 1'b1; end
                    else timer <= timer + 1'b1;
                end
                S_SCAN: begin status <= 1; attempted <= 0; scan_start <= 1'b1; state <= S_SCAN_WAIT; end
                S_SCAN_WAIT: begin
                    if (!sd_init_done) state <= S_WAIT_INIT;
                    else if (scan_done) state <= scan_failed ? S_RETRY : S_PICK;
                end
                S_PICK: begin
                    if (!sd_init_done) state <= S_WAIT_INIT;
                    else if (todo == 0) state <= S_DONE;
                    else begin
                        slot <= first; file_size <= sizes[first*32 +: 32]; state <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    // slot/file_size are registered; start the streamer and the decoder together
                    status <= 2; busy <= 1'b1; file_start <= 1'b1; file_abort <= 0; state <= S_LOAD_WAIT;
                end
                S_LOAD_WAIT: begin
                    if (!sd_init_done) begin busy <= 0; state <= S_WAIT_INIT; end
                    else if (dec_bad_header) begin
                        // stop reading a rejected file; the streamer finishes its sector, then idles
                        file_abort <= 1'b1; attempted[slot] <= 1'b1; state <= S_DRAIN;
                    end else if (dec_done) begin
                        attempted[slot] <= 1'b1; card_ready[slot] <= dec_ok; busy <= 0; state <= S_PICK;
                    end
                end
                S_DRAIN: if (!file_busy) begin file_abort <= 0; busy <= 0; state <= S_PICK; end
                S_DONE: begin status <= 3; busy <= 0; if (!sd_init_done) state <= S_WAIT_INIT; end
                S_RETRY: begin
                    status <= 4;
                    if (timer >= RETRY_LIMIT - 1) begin timer <= 0; sd_reset_req <= 1'b1; state <= S_WAIT_INIT; end
                    else timer <= timer + 1'b1;
                end
                default: state <= S_WAIT_INIT;
            endcase
        end
    end
endmodule

// 256-colour BMP card decoder. Accepts exactly CW x CH, 8 bits per pixel, BI_RGB (no compression),
// bottom-up rows, BITMAPINFOHEADER or a larger V4/V5 header (40..124 bytes), up to 256 palette
// entries. Bytes arrive in file order (fat32_file_streamer) and are never back-pressured.
//   palette entry i of card c -> pal[c*256 + i] = {R,G,B}
//   pixel (x, y), y = 0 at the top -> pix[c*CW*CH + y*CW + x] = palette index
// bad_header pulses once if the header is rejected (the loader then aborts the stream);
// done pulses once at the end with ok = header accepted and all CW*CH pixels written.
module clinic_bmp8_decode #(
    parameter integer CW = 120, CH = 90
)(
    input wire clk, rst, start,
    input wire [2:0] card,
    input wire [16:0] file_size,
    input wire byte_valid, input wire [7:0] byte_data,
    input wire stream_done, stream_failed,
    output reg done, ok, bad_header,
    output reg pix_we, output reg [15:0] pix_waddr, output reg [7:0] pix_wdata,
    output reg pal_we, output reg [10:0] pal_waddr, output reg [23:0] pal_wdata
);
    localparam integer PIXELS = CW * CH;
    localparam integer ROW_STRIDE = (CW + 3) / 4 * 4;
    reg active, header_checked, header_ok;
    reg [16:0] offset;
    reg [7:0] magic0, magic1;
    reg [31:0] pix_off, dib_size, width, height, compression, clr_used;
    reg [15:0] planes, bpp;
    reg [2:0] card_q;
    reg [16:0] pal_start, pal_end;
    reg [7:0] blue, green;
    reg [13:0] pix_count;
    reg [6:0] col;                  // 0..CW-1
    reg [15:0] row_addr;            // address of column 0 of the current row
    reg [6:0] pad;                  // padding bytes left at the end of a file row (CW multiple of 4: none)
    wire [16:0] rel_pal = offset - pal_start;
    wire in_header = offset < 17'd54;
    wire in_palette = header_ok && offset >= pal_start && offset < pal_end;
    wire in_pixels = header_ok && offset >= pix_off[16:0] && pix_count < PIXELS;
    function [31:0] le32; input [31:0] v; input [1:0] lane; input [7:0] b;
        begin le32 = v; le32[lane*8 +: 8] = b; end
    endfunction
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 0; header_checked <= 0; header_ok <= 0; offset <= 0; done <= 0; ok <= 0; bad_header <= 0;
            magic0 <= 0; magic1 <= 0; pix_off <= 0; dib_size <= 0; width <= 0; height <= 0;
            compression <= 0; clr_used <= 0; planes <= 0; bpp <= 0; card_q <= 0;
            pal_start <= 0; pal_end <= 0; blue <= 0; green <= 0; pix_count <= 0; col <= 0; row_addr <= 0; pad <= 0;
            pix_we <= 0; pix_waddr <= 0; pix_wdata <= 0; pal_we <= 0; pal_waddr <= 0; pal_wdata <= 0;
        end else begin
            done <= 0; bad_header <= 0; pix_we <= 0; pal_we <= 0;
            if (start) begin
                active <= 1; header_checked <= 0; header_ok <= 0; offset <= 0; card_q <= card;
                pix_count <= 0; col <= 0; pad <= 0;
                // first file row is the bottom picture row
                row_addr <= card * PIXELS + (CH - 1) * CW;
            end else if (active) begin
                // header fields, little endian
                if (byte_valid && in_header) begin
                    case (offset[5:0])
                        0: magic0 <= byte_data;
                        1: magic1 <= byte_data;
                        10, 11, 12, 13: pix_off <= le32(pix_off, offset[1:0] - 2'd2, byte_data);
                        14, 15, 16, 17: dib_size <= le32(dib_size, offset[1:0] - 2'd2, byte_data);
                        18, 19, 20, 21: width <= le32(width, offset[1:0] - 2'd2, byte_data);
                        22, 23, 24, 25: height <= le32(height, offset[1:0] - 2'd2, byte_data);
                        26: planes[7:0] <= byte_data;
                        27: planes[15:8] <= byte_data;
                        28: bpp[7:0] <= byte_data;
                        29: bpp[15:8] <= byte_data;
                        30, 31, 32, 33: compression <= le32(compression, offset[1:0] - 2'd2, byte_data);
                        46, 47, 48, 49: clr_used <= le32(clr_used, offset[1:0] - 2'd2, byte_data);
                        default: ;
                    endcase
                end
                // all header fields are in once offset reaches 50 (the next byte is >= 2 clocks away)
                if (!header_checked && offset == 17'd50) begin
                    header_checked <= 1;
                    pal_start <= 17'd14 + dib_size[16:0];
                    pal_end <= 17'd14 + dib_size[16:0] + ((clr_used == 0 ? 17'd256 : {8'd0, clr_used[8:0]}) << 2);
                    header_ok <= magic0 == "B" && magic1 == "M" && width == CW && height == CH &&
                                 planes == 1 && bpp == 8 && compression == 0 && clr_used <= 256 &&
                                 dib_size >= 40 && dib_size <= 124 &&
                                 pix_off >= 14 + dib_size + ((clr_used == 0 ? 32'd256 : clr_used) << 2) &&
                                 pix_off + ROW_STRIDE * CH <= {15'd0, file_size};
                end
                if (header_checked && !header_ok && active) begin
                    active <= 0; bad_header <= 1; done <= 1; ok <= 0;
                end
                if (byte_valid) begin
                    offset <= offset + 1'b1;
                    if (in_palette) begin
                        case (rel_pal[1:0])
                            0: blue <= byte_data;
                            1: green <= byte_data;
                            2: begin pal_we <= 1; pal_waddr <= {card_q, rel_pal[9:2]}; pal_wdata <= {byte_data, green, blue}; end
                            default: ;
                        endcase
                    end
                    if (in_pixels) begin
                        if (pad != 0) pad <= pad - 1'b1;
                        else begin
                            pix_we <= 1; pix_waddr <= row_addr + col; pix_wdata <= byte_data;
                            pix_count <= pix_count + 1'b1;
                            if (col == CW - 1) begin
                                col <= 0; row_addr <= row_addr - CW; pad <= ROW_STRIDE - CW;
                            end else col <= col + 1'b1;
                        end
                    end
                end
                if (stream_done || stream_failed) begin
                    active <= 0; done <= 1;
                    ok <= stream_done && header_ok && pix_count == PIXELS;
                end
            end
        end
    end
endmodule
