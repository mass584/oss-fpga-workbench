// ============================================================================
// PSRAM フレームバッファ管理 (メモリクロックドメイン)
//
//   cam FIFO ──► writer ─┐                    ┌─► line buffer (ping-pong)
//                        ├─► arbiter ─► psram_ctrl
//   line req ──► reader ─┘  (読み出し優先,     │
//                           バースト単位)      └─ line done ──► 表示側
//
//   メモリマップ (ダイ内 16bit ワードアドレス。1 ワード = 2 画素 = 2 ダイ x 2B):
//     バッファ b の先頭 = b * 0x40000 (各ダイ 512KB, 2 ダイで 1MB 刻み)
//     画素 (x, y) = 先頭 + (y*640 + x) / 2      1 フレーム = 153,600 ワード (614,400B)
//     調整用領域 = 0x1C0000
//   バーストは BL ワードで BL ワード境界に揃える。実機のデバイスは CA で連続バーストを
//   指定しても 16 ワード (各ダイ 32 バイト) で折り返したので、BL=16 で使う (折り返しと一致)。
//
//   トリプルバッファ (状態はすべてこのドメインに置き、他ドメインとはイベントだけ受け渡す):
//     disp   : 表示中。表示側の垂直ブランク開始イベントで latest に切り替える
//     latest : 最新の完成フレーム
//     wr     : 書き込み中。常に disp, latest のどちらとも異なる
//   フレーム書き込み完了で latest <= wr とし、wr には残りの 1 面を選ぶ。
//   → 表示中のバッファには決して書かない (ティアリングなし)。
//
//   書き込みパスのフレーム同期:
//     FIFO エントリは {sof, 偶数画素, 奇数画素}。cam_pack が SOF をバースト境界に揃える。
//     SOF を見たら書き込み位置を先頭に戻す (途中で崩れたフレームは完成扱いにしない)。
//     完成後〜次の SOF までのエントリは捨てる。
// ============================================================================
module psram_fb #(
    parameter integer BL          = 32,
    parameter integer FIFO_AW     = 9,
    parameter integer FRAME_WORDS = 640 * 480 / 2,
    parameter integer LINE_WORDS  = 640 / 2,
    // 1: PSRAM には 1 画素 14bit (R5 G5 B4) で保存する。各バイトの bit7 を使わない。
    //    実機 (OSS フロー) では PSRAM の各バイトの bit7 が書き込めなかったための回避策
    parameter integer PIX14       = 1
)(
    input  wire        clk,
    input  wire        rst,

    // カメラ FIFO (FWFT)
    input  wire [32:0]        fifo_dout,
    input  wire               fifo_valid,
    input  wire [FIFO_AW+1:0] fifo_count,
    output wire               fifo_rd,

    // 表示側からのイベント (非同期。トグル + 値保持)
    input  wire        line_req_tog,
    input  wire [8:0]  line_req_num,
    input  wire        vblank_tog,

    // 表示側へ (トグル + 値保持)
    output reg         line_done_tog,
    output reg  [8:0]  line_done_num,

    // ラインバッファ書き込み {面, ワード位置}
    output reg         lb_we,
    output reg  [9:0]  lb_waddr,
    output reg  [31:0] lb_wdata,

    // psram_ctrl
    input  wire        mem_init_done,
    input  wire        mem_ready,
    output reg         mem_req,
    output reg         mem_req_we,
    output reg  [20:0] mem_req_addr,
    input  wire        mem_wd_take,
    output wire [31:0] mem_wd,
    input  wire        mem_rd_valid,
    input  wire [31:0] mem_rd_data,
    input  wire        mem_xfer_done,
    input  wire        mem_rd_err,

    // 状態 (デバッグ / 検証用)
    output reg         frame_wr_tog,     // フレームを 1 枚書き終えるごとに反転
    output reg  [1:0]  disp_buf,
    output reg  [1:0]  wr_buf,
    output reg  [1:0]  latest_buf,
    output reg         rd_err_seen,      // 読み出しエラーが一度でもあった
    output reg         frame_broken      // SOF がバースト途中に来た (起きないはず)
);
    localparam integer BLW       = $clog2(BL);           // バースト内ワード番号のビット幅
    localparam integer KW        = 9 - BLW;              // ライン内バースト番号のビット幅 (ライン 512 ワード以下)
    localparam integer LAST_K_I  = LINE_WORDS / BL - 1;  // 1 ラインのバースト数 - 1
    localparam [17:0]  FRAME_END = FRAME_WORDS[17:0];
    localparam [KW-1:0] LAST_K   = LAST_K_I[KW-1:0];

    // ------------------------------------------------------------------
    // 表示側イベントの同期化
    // ------------------------------------------------------------------
    wire lreq_s, vbl_s;
    cdc_sync #(.W(2)) u_sync (.clk(clk), .d({line_req_tog, vblank_tog}), .q({lreq_s, vbl_s}));
    reg  lreq_d, vbl_d;
    always @(posedge clk) begin lreq_d <= lreq_s; vbl_d <= vbl_s; end
    wire lreq_ev = lreq_s ^ lreq_d;     // line_req_num はこの時点で安定している
    wire vbl_ev  = vbl_s  ^ vbl_d;

    // ------------------------------------------------------------------
    // 状態
    // ------------------------------------------------------------------
    reg        latest_valid;
    reg        frame_active;     // 書き込み中のフレームがある
    reg [17:0] wptr;             // 書き込み位置 (ワード, BL 単位で進む)

    reg        rd_active;        // ライン読み出しの残りバーストがある
    reg [8:0]  rd_line;
    reg [KW-1:0] rd_k;

    // 実行中トランザクション
    reg        busy, inf_we, inf_last;
    reg [8:0]  inf_line;
    reg [KW-1:0]  inf_k;
    reg [BLW-1:0] inf_widx;
    reg [BLW-1:0] take_idx;
    reg        inf_err;

    // ------------------------------------------------------------------
    // 要求の判定
    // ------------------------------------------------------------------
    wire head_sof = fifo_valid && fifo_dout[32];
    wire can_issue = mem_ready && !busy && !mem_req;
    wire want_rd   = rd_active;
    wire want_wr   = frame_active && fifo_valid && (fifo_count >= BL[FIFO_AW+1:0]) &&
                     (!head_sof || wptr == 18'd0);
    // 書き込みトランザクション中以外で、FIFO 先頭のフレーム同期処理
    wire sof_restart = !busy && !mem_req && head_sof && !(frame_active && wptr == 18'd0);
    wire discard     = !busy && !mem_req && fifo_valid && !head_sof && !frame_active;

    // RGB565 <-> PSRAM 上の 16bit (bit15, bit7 は未使用)。G と B の最下位ビットを捨てる
    //   書き込み: {R5, G[5:1], B[4:1]} -> {0, R5, G[5:4], 0, G[3:1], B[4:1]}
    function [15:0] pack14(input [4:0] r, input [4:0] g, input [3:0] b);
        pack14 = {1'b0, r, g[4:3], 1'b0, g[2:0], b};
    endfunction
    function [15:0] unpack14(input [6:0] hi, input [6:0] lo);   // -> RGB565 (落とした LSB は 0)
        unpack14 = {hi[6:2], hi[1:0], lo[6:4], 1'b0, lo[3:0], 1'b0};
    endfunction

    wire [31:0] wd14 = {pack14(fifo_dout[31:27], fifo_dout[26:22], fifo_dout[20:17]),
                        pack14(fifo_dout[15:11], fifo_dout[10:6],  fifo_dout[4:1])};
    wire [31:0] rd14 = {unpack14(mem_rd_data[30:24], mem_rd_data[22:16]),
                        unpack14(mem_rd_data[14:8],  mem_rd_data[6:0])};

    assign fifo_rd = mem_wd_take || discard;
    assign mem_wd  = (PIX14 != 0) ? wd14 : fifo_dout[31:0];

    wire [20:0] disp_base = {1'b0, disp_buf, 18'd0};
    wire [20:0] wr_base   = {1'b0, wr_buf,   18'd0};
    wire [17:0] line_off  = {1'b0, rd_line, 8'd0} + {3'b0, rd_line, 6'd0};   // rd_line * 320

    // 垂直ブランクでの切り替え後の disp (同サイクルのフレーム完成と矛盾しないように先に求める)
    wire [1:0] disp_next = (vbl_ev && latest_valid) ? latest_buf : disp_buf;

    always @(posedge clk) begin
        mem_req <= 1'b0;
        lb_we   <= 1'b0;

        if (rst) begin
            line_done_tog <= 1'b0; line_done_num <= 9'd0;
            lb_waddr <= 10'd0; lb_wdata <= 32'd0;
            mem_req_we <= 1'b0; mem_req_addr <= 21'd0;
            frame_wr_tog <= 1'b0;
            disp_buf <= 2'd0; latest_buf <= 2'd0; latest_valid <= 1'b0; wr_buf <= 2'd1;
            frame_active <= 1'b0; wptr <= 18'd0;
            rd_active <= 1'b0; rd_line <= 9'd0; rd_k <= {KW{1'b0}};
            busy <= 1'b0; inf_we <= 1'b0; inf_last <= 1'b0; inf_line <= 9'd0; inf_k <= {KW{1'b0}};
            inf_widx <= {BLW{1'b0}}; take_idx <= {BLW{1'b0}}; inf_err <= 1'b0;
            rd_err_seen <= 1'b0; frame_broken <= 1'b0;
        end else begin
            disp_buf <= disp_next;

            // ---- 読み出し要求 (新しい要求が来たら古いラインは打ち切る) ----
            if (lreq_ev) begin
                rd_line   <= line_req_num;
                rd_k      <= {KW{1'b0}};
                rd_active <= mem_init_done;
            end

            // ---- 書き込み側のフレーム同期 ----
            // 途中まで書いたフレームがあっても完成扱いにせず、同じ面の先頭から書き直す
            if (sof_restart) begin
                frame_active <= 1'b1;
                wptr         <= 18'd0;
            end

            // ---- アービタ: 読み出し優先、バースト単位 ----
            if (can_issue && !lreq_ev) begin
                if (want_rd) begin
                    mem_req      <= 1'b1;
                    mem_req_we   <= 1'b0;
                    mem_req_addr <= disp_base + {3'b0, line_off} + {12'd0, rd_k, {BLW{1'b0}}};
                    busy <= 1'b1; inf_we <= 1'b0; inf_line <= rd_line; inf_k <= rd_k;
                    inf_widx <= {BLW{1'b0}}; inf_err <= 1'b0;
                    rd_k <= rd_k + 1'b1;
                    if (rd_k == LAST_K) rd_active <= 1'b0;
                end else if (want_wr && !sof_restart) begin
                    mem_req      <= 1'b1;
                    mem_req_we   <= 1'b1;
                    mem_req_addr <= wr_base + {3'b0, wptr};
                    busy <= 1'b1; inf_we <= 1'b1; take_idx <= {BLW{1'b0}};
                    inf_last <= (wptr + BL[17:0] == FRAME_END);
                    wptr <= wptr + BL[17:0];
                    if (wptr + BL[17:0] == FRAME_END) frame_active <= 1'b0;
                end
            end

            // ---- 書き込みデータ消費中: SOF がバースト途中にあれば異常 ----
            if (mem_wd_take) begin
                take_idx <= take_idx + 1'b1;
                if (take_idx != {BLW{1'b0}} && fifo_dout[32]) begin
                    frame_broken <= 1'b1;
                    frame_active <= 1'b0;
                end
            end

            // ---- 読み出しデータ -> ラインバッファ ----
            if (mem_rd_valid) begin
                lb_we    <= 1'b1;
                lb_waddr <= {inf_line[0], inf_k, inf_widx};   // 面, k*BL + i
                lb_wdata <= (PIX14 != 0) ? rd14 : mem_rd_data;
                inf_widx <= inf_widx + 1'b1;
            end
            if (mem_rd_err) begin
                inf_err     <= 1'b1;
                rd_err_seen <= 1'b1;
            end

            // ---- トランザクション終了 ----
            if (mem_xfer_done) begin
                busy <= 1'b0;
                if (!inf_we && inf_k == LAST_K && !inf_err && !mem_rd_err) begin
                    line_done_num <= inf_line;
                    line_done_tog <= ~line_done_tog;
                end
                if (inf_we && inf_last) begin
                    // フレーム完成: latest を更新し、残りの 1 面へ次を書く
                    latest_buf   <= wr_buf;
                    latest_valid <= 1'b1;
                    wr_buf       <= 2'd3 - disp_next - wr_buf;
                    frame_wr_tog <= ~frame_wr_tog;
                end
            end
        end
    end
endmodule
