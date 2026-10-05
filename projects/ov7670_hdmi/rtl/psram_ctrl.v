// ============================================================================
// GW1NR-9C 内蔵 PSRAM コントローラ (HyperBus 系, 2 ダイ並列 x16)
//
//   GW1NR-9C には 32Mbit x8 の PSRAM ダイが 2 個入っている。両ダイに同じ CK/CS/CA を
//   与えて並列に動かし、dq[15:8] (ダイ1) と dq[7:0] (ダイ0) で 16bit DDR として使う。
//   1 クロックで 32bit = 2 画素を転送する。
//     ワード (32bit) = {立ち上がり側 16bit, 立ち下がり側 16bit}
//     アドレス       = ダイ内の 16bit ワードアドレス (21bit, 2M ワード = 4MB/ダイ)
//
//   Gowin 純正 IP は OSS フローでは使えないので自作。ベンダ依存部は ODDR/IDDR/IOBUF のみ。
//
//   クロック:
//     clk   : コントローラと全 IO レジスタのクロック (CK と同じ周波数)
//     clk_p : clk を 90° 遅らせたもの。CK を出す ODDR 専用。DQ/CS# は clk の両エッジで変化し、
//             CK のエッジはその中央に来る (書き込み/CA のセンターアライン)。
//             CK は CS# Low の間だけ出す。CS# はサイクルの頭 (CK が Low の間) で下げ、
//             最初の CK 立ち上がりは T/4 後 (tCSS)。CK が High のときに CS# を下げると、
//             デバイスは直後の立ち下がりから CA を数えてしまい CA が半クロックずれる。
//
//   タイミングで実機依存の部分は自己調整する:
//     - 読み出し: RWDS の 1010 パターンを探してデータの先頭と半周期位相を自動で合わせる
//       (CA 中の RWDS=High → レイテンシ中の Low → トグル開始、の順で検出)
//     - 書き込み: CA 終了からデータまでのクロック数 (gap) を初期化時に G_MIN..G_MAX で
//       順に試し、書いて読み戻して一致した値を採用する
//
//   バーストは BL ワード固定。アドレスは BL 境界に揃えること (ページ境界をまたがない)。
//   CS# Low 時間は最長でも約 100 クロック (tCSM 4us 以内 @ 63MHz)。
//   実機の参考実装: zf3/psram-tang-nano-9k (CK ゲーティング、CR0、CA 形式を照合済み)
// ============================================================================
/* verilator lint_off PINCONNECTEMPTY */   // ベンダプリミティブの未使用出力 (ODDR.Q1)
module psram_ctrl #(
    parameter integer CLK_HZ   = 63_000_000,
    parameter integer INIT_US  = 200,          // 電源投入待ち / リセット解除後待ち (各)
    parameter integer BL       = 32,           // バースト長 (クロック数 = 32bit ワード数)
    // CR0: 通常動作, 駆動力既定, 初期レイテンシ 3 クロック, 固定レイテンシ(2倍), 既定バースト設定
    parameter [15:0]  CR0      = 16'h8FEF,
    parameter integer G_MIN    = 3,            // 書き込み gap 探索範囲
    parameter integer G_MAX    = 14,           //  (レイテンシ3固定=5, CR0 未反映の既定6固定=11 を含む)
    parameter integer T_RECOV  = 6,            // CS# High 期間 (パイプラインの残りを捨てる時間を含む)
    parameter [20:0]  CAL_ADDR = 21'h1C0000,   // 調整用の領域 (フレームバッファと重ならない)
    // CK の作り方: 0 = clk_p (PLL の位相シフト出力, 既定 90°) で作る。実機で CA/読み出しが通るのを確認済み
    //              1 = clk の反転 (180°)。実機ではデバイスが応答しなかった (切り分け用に残す)
    parameter integer CK_MODE  = 0,
    // 調整で比較するビット。実機 (OSS フロー) では各バイトの bit7 が書き込めないので除外する
    parameter [31:0]  CAL_MASK = 32'h7F7F7F7F,
    // 1: 初期化で CR0 を書く。実機では CR0 の書き込み結果が不正 (0x8FEF -> 0x8F8F) だったので
    //    既定は書かずに CR0 既定値 (固定レイテンシ 6) で使う。書き込み gap は自動調整で決まる
    parameter integer WRITE_CR0 = 0
)(
    input  wire        clk,
    input  wire        clk_p,
    input  wire        rst,

    output reg         init_done,      // 調整成功。以後 req を受け付ける
    output reg         init_fail,      // 1 回以上調整に失敗した (成功するまでやり直す)
    output reg  [3:0]  wr_gap,         // 採用した書き込み gap (状態表示用)

    // ユーザ側 (clk ドメイン)
    output wire        ready,          // req を受け付けられる
    input  wire        req,            // ready の間に 1 サイクル立てると受付
    input  wire        req_we,         // 1=書き込み 0=読み出し
    input  wire [20:0] req_addr,       // ワードアドレス (BL 境界)
    output wire        wd_take,        // このサイクルで wd を消費する (書き込み)
    input  wire [31:0] wd,
    output reg         rd_valid,       // 読み出しデータ (BL 回)
    output reg  [31:0] rd_data,
    output reg         xfer_done,      // トランザクション終了 (CS# High にした)
    output reg         rd_err,         // 読み出しで RWDS が見つからなかった/欠けた

    // PSRAM (GW1NR-9C 内部ピン。ポート名で自動配置される)
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds
);
    localparam integer T_INIT = (CLK_HZ / 1_000_000) * INIT_US;
    localparam integer N_TO   = 4 + 2 * G_MAX + BL + 24;   // 読み出しタイムアウト
    // CS# を上げるサイクルの前半の値。CK 180° では最後の CK 立ち下がりが前サイクルの終わりに
    // 来るので、CS# は半サイクル遅らせて上げる (tCSH)
    localparam CS_END0 = (CK_MODE == 1) ? 1'b0 : 1'b1;

    // ------------------------------------------------------------------
    // 状態
    // ------------------------------------------------------------------
    localparam [3:0] ST_PWR = 4'd0, ST_RSTH = 4'd1, ST_CFG = 4'd2, ST_CAL_W = 4'd3,
                     ST_CAL_R = 4'd4, ST_CAL_CHK = 4'd5, ST_IDLE = 4'd6, ST_XFER = 4'd7,
                     ST_RECOV = 4'd8, ST_ID = 4'd9, ST_CRA = 4'd10, ST_CRB = 4'd11;
    localparam [1:0] OP_RD = 2'd0, OP_WR = 2'd1, OP_REG = 2'd2, OP_RRD = 2'd3;   // OP_RRD: レジスタ読み出し

    reg [3:0]  st, ret_st;
    reg [1:0]  op;
    reg [20:0] t_addr;
    reg [3:0]  t_gap;
    reg        t_user;          // ユーザのトランザクション (0: 調整用)
    reg [7:0]  n;               // トランザクション内サイクル
    reg [15:0] tmr;
    reg [3:0]  cand;            // 調整中の gap 候補
    reg        cal_ok;
    reg        rst_n_r;

    assign ready = (st == ST_IDLE);

    // IO レジスタへ渡す値 (全出力が同じ段数を通るので互いに揃う)
    reg        o_cs0, o_cs1;    // CS# の前半/後半
    reg [15:0] o_dq0, o_dq1;    // DQ の前半(立ち上がり側)/後半
    reg        o_dqoe, o_rwoe;
    reg        o_rwm0, o_rwm1;  // RWDS の前半/後半 (書き込みマスク。1 = そのバイトを書かない)
    reg        o_ck;            // CK を出す (CS# Low の間)

    // ------------------------------------------------------------------
    // CA (48bit): [47]R/W# [46]AS [45]線形バースト [44:16]A[31:3] [2:0]A[2:0]
    // ------------------------------------------------------------------
    wire        op_rd = (op == OP_RD) || (op == OP_RRD);
    wire [47:0] ca = {op_rd, op == OP_REG || op == OP_RRD, 1'b1, 11'b0, t_addr[20:3], 13'b0, t_addr[2:0]};
    reg  [15:0] ca_word;        // n=1..3 で送る 16bit (前半=上位バイト)
    always @* begin
        case (n)
            8'd1:    ca_word = ca[47:32];
            8'd2:    ca_word = ca[31:16];
            default: ca_word = ca[15:0];
        endcase
    end

    // 調整用パターン (ワード番号 i と候補 c で変わる。ずれたワードとは一致しない)
    //   各バイトの bit7 は使わない (実機で書き込めないため 0)。i の全ビットを下位 7bit に入れて
    //   32 ワードすべて異なる値にする (折り返し/ずれを見分けるため)
    function [31:0] cal_pat(input [4:0] i, input [3:0] c);
        cal_pat = {1'b0, i, c[1:0], 1'b0, ~i, c[3:2], 1'b0, i + 5'd7, 2'b10, 1'b0, i ^ 5'h15, c[0], 1'b1};
    endfunction

    wire [7:0] wd_first = 8'd4 + {4'd0, t_gap};             // 書き込みデータ先頭の n
    wire [7:0] wd_end   = wd_first + BL[7:0];                // CS# を上げる n
    wire       in_wdata = (st == ST_XFER) && (op == OP_WR) && (n >= wd_first) && (n < wd_end);
    wire [4:0] wd_idx5  = n[4:0] - wd_first[4:0];
    wire [31:0] wsrc    = t_user ? wd : cal_pat(wd_idx5, t_gap);
    assign wd_take = in_wdata && t_user;

    // ------------------------------------------------------------------
    // 読み出しキャプチャ
    // ------------------------------------------------------------------
    wire [15:0] dq_q0, dq_q1;       // IDDR 出力 (q0 = 先にサンプルした立ち上がり側)
    wire [1:0]  rw_q0, rw_q1;
    reg  [15:0] c_dq0, c_dq1, p_dq0, p_dq1;
    reg         c_rw0, c_rw1, p_rw0, p_rw1;
    reg         rw_mis;             // 2 ダイの RWDS が食い違った

    always @(posedge clk) begin
        c_dq0 <= dq_q0; c_dq1 <= dq_q1; c_rw0 <= rw_q0[0]; c_rw1 <= rw_q1[0];
        p_dq0 <= c_dq0; p_dq1 <= c_dq1; p_rw0 <= c_rw0;    p_rw1 <= c_rw1;
        rw_mis <= (rw_q0[0] ^ rw_q0[1]) | (rw_q1[0] ^ rw_q1[1]);
    end

    localparam [2:0] RS_WHI = 3'd0, RS_WLO = 3'd1, RS_FIND = 3'd2, RS_CAP = 3'd3, RS_DONE = 3'd4;
    reg [2:0] rs;
    reg       rphase;               // 0: ワード = (p0,p1)  1: ワード = (p1,c0)
    reg [5:0] widx;
    reg [1:0] lowrun;
    wire [31:0] rword = rphase ? {p_dq1, c_dq0} : {p_dq0, p_dq1};

    // 読み出しワードの取り出し (FIND で先頭を見つけ、CAP で残りを毎サイクル取る)
    reg        cap_fire, err_fire;
    reg [31:0] cap_word;
    reg [4:0]  cap_idx;
    always @* begin
        cap_fire = 1'b0; err_fire = 1'b0; cap_word = rword; cap_idx = widx[4:0];
        if (st == ST_XFER && op_rd) begin
            case (rs)
            RS_FIND: begin
                cap_idx = 5'd0;
                if (p_rw0) begin                // 先頭が立ち上がり側サンプル
                    cap_fire = 1'b1;
                    cap_word = {p_dq0, p_dq1};
                    err_fire = !(!p_rw1 && c_rw0);
                end else if (p_rw1) begin       // 半周期ずれている
                    cap_fire = 1'b1;
                    cap_word = {p_dq1, c_dq0};
                    err_fire = !(!c_rw0 && c_rw1);
                end
            end
            RS_CAP: begin
                // RWDS がこのワードの位置で 1->0 になっているときだけ取り込む
                // (デバイスが途中で待ちを入れても同じデータを二重に拾わない)
                cap_fire = rphase ? (p_rw1 && !c_rw0) : (p_rw0 && !p_rw1);
                err_fire = cap_fire && rw_mis;
            end
            default: ;
            endcase
            if (rs != RS_DONE && n == N_TO[7:0]) err_fire = 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // メイン FSM
    // ------------------------------------------------------------------
    task automatic start_xfer(input [1:0] t_op, input [20:0] a, input [3:0] g,
                              input u, input [3:0] ret);
        begin
            op <= t_op; t_addr <= a; t_gap <= g; t_user <= u; ret_st <= ret;
            n <= 8'd0; rs <= RS_WHI; widx <= 6'd0; lowrun <= 2'd0;
            st <= ST_XFER;
        end
    endtask

    always @(posedge clk) begin
        rd_valid  <= 1'b0;
        xfer_done <= 1'b0;
        rd_err    <= 1'b0;

        if (rst) begin
            st <= ST_PWR; ret_st <= ST_IDLE; tmr <= 16'd0; rst_n_r <= 1'b0;
            op <= OP_RD; t_addr <= 21'd0; t_gap <= 4'd0; t_user <= 1'b0; n <= 8'd0;
            cand <= G_MIN[3:0]; cal_ok <= 1'b0;
            init_done <= 1'b0; init_fail <= 1'b0; wr_gap <= 4'd0;
            rs <= RS_DONE; rphase <= 1'b0; widx <= 6'd0; lowrun <= 2'd0;
            o_cs0 <= 1'b1; o_cs1 <= 1'b1; o_dq0 <= 16'd0; o_dq1 <= 16'd0;
            o_dqoe <= 1'b0; o_rwoe <= 1'b0; o_ck <= 1'b0; o_rwm0 <= 1'b1; o_rwm1 <= 1'b1;
        end else begin
            // 既定: CS# High, CK 停止, バス解放
            o_cs0 <= 1'b1; o_cs1 <= 1'b1; o_dqoe <= 1'b0; o_rwoe <= 1'b0; o_ck <= 1'b0; o_rwm0 <= 1'b1; o_rwm1 <= 1'b1;

            case (st)
            // 電源投入: RESET# Low で待ち、解放後さらに待つ (tVCS 150us 以上)
            ST_PWR: begin
                tmr <= tmr + 1'b1;
                if (tmr == T_INIT[15:0]) begin tmr <= 16'd0; rst_n_r <= 1'b1; st <= ST_RSTH; end
            end
            ST_RSTH: begin
                tmr <= tmr + 1'b1;
                if (tmr == T_INIT[15:0]) begin tmr <= 16'd0; st <= ST_ID; end
            end
            // ID0 と CR0 を読む (値は使わない)。立ち上げ時のデバッグ用だったが、実機で調整が通っている
            // 初期化の手順を変えないために読み出しのトランザクションだけ残している
            ST_ID:  start_xfer(OP_RRD, 21'h000000, 4'd0, 1'b0, ST_CRA);
            ST_CRA: start_xfer(OP_RRD, 21'h000800, 4'd0, 1'b0, ST_CFG);
            ST_CRB: start_xfer(OP_RRD, 21'h000800, 4'd0, 1'b0, ST_CAL_W);
            // CR0 書き込み (レジスタ空間 0x800, レイテンシなし)
            ST_CFG: begin
                cand <= G_MIN[3:0];
                if (WRITE_CR0 != 0) start_xfer(OP_REG, 21'h000800, 4'd0, 1'b0, ST_CRB);
                else                st <= ST_CRB;
            end
            ST_CAL_W: start_xfer(OP_WR, CAL_ADDR, cand, 1'b0, ST_CAL_R);
            ST_CAL_R: begin
                cal_ok <= 1'b1;
                start_xfer(OP_RD, CAL_ADDR, cand, 1'b0, ST_CAL_CHK);
            end
            ST_CAL_CHK: begin
                if (cal_ok) begin
                    wr_gap    <= cand;
                    init_done <= 1'b1;
                    st        <= ST_IDLE;
                end else if (cand == G_MAX[3:0]) begin
                    init_fail <= 1'b1;            // 全候補 NG: CR0 から全部やり直す
                    st        <= ST_CFG;
                end else begin
                    cand <= cand + 1'b1;
                    st   <= ST_CAL_W;
                end
            end
            ST_IDLE: begin
                if (req) start_xfer(req_we ? OP_WR : OP_RD, req_addr, wr_gap, 1'b1, ST_IDLE);
            end

            // ---- 1 トランザクション ----
            ST_XFER: begin
                n <= n + 1'b1;
                // n=0 は CS# High のまま。n=1 (CA の先頭) からサイクルの頭で CS# を下げる
                o_cs0 <= (n == 8'd0);
                o_cs1 <= (n == 8'd0);
                o_ck  <= (n != 8'd0);
                if (n >= 8'd1 && n <= 8'd3) begin  // CA
                    o_dqoe <= 1'b1;
                    o_dq0  <= {2{ca_word[15:8]}};
                    o_dq1  <= {2{ca_word[7:0]}};
                end
                case (op)
                OP_REG: begin
                    if (n == 8'd4) begin
                        o_dqoe <= 1'b1;
                        o_dq0  <= {2{CR0[15:8]}};
                        o_dq1  <= {2{CR0[7:0]}};
                    end
                    if (n == 8'd5) begin
                        o_cs0 <= CS_END0; o_cs1 <= 1'b1; o_ck <= 1'b0;
                        st <= ST_RECOV; tmr <= 16'd0;
                    end
                end
                OP_WR: begin
                    if (in_wdata) begin
                        o_dqoe <= 1'b1;
                        o_rwoe <= 1'b1;
                        o_rwm0 <= 1'b0;           // マスクなし
                        o_rwm1 <= 1'b0;
                        o_dq0  <= wsrc[31:16];
                        o_dq1  <= wsrc[15:0];
                    end
                    if (n == wd_end) begin
                        o_cs0 <= CS_END0; o_cs1 <= 1'b1; o_ck <= 1'b0;
                        st <= ST_RECOV; tmr <= 16'd0;
                    end
                end
                default: begin                    // OP_RD
                    case (rs)
                    RS_WHI: if (n >= 8'd2 && (c_rw0 || c_rw1)) begin
                        rs <= RS_WLO; lowrun <= 2'd0;
                    end
                    RS_WLO: begin
                        if (!c_rw0 && !c_rw1) begin
                            lowrun <= lowrun + 1'b1;
                            if (lowrun == 2'd1) rs <= RS_FIND;
                        end else begin
                            lowrun <= 2'd0;
                        end
                    end
                    RS_FIND: if (cap_fire) begin
                        rphase <= !p_rw0;
                        widx   <= 6'd1;
                        rs     <= RS_CAP;
                    end
                    RS_CAP: if (cap_fire) begin
                        widx <= widx + 1'b1;
                        // 1 ワード余分に読んでから終える (実機では最後に読んだワードの後半が
                        // 前半と同じ値になったため。余分なワードは捨てる)
                        if (widx == BL[5:0]) rs <= RS_DONE;
                    end
                    default: ;
                    endcase
                    if (rs == RS_DONE || n == N_TO[7:0]) begin
                        o_cs0 <= CS_END0; o_cs1 <= 1'b1; o_ck <= 1'b0;
                        st <= ST_RECOV; tmr <= 16'd0;
                    end
                end
                endcase
            end

            ST_RECOV: begin
                if (tmr == 16'd0) xfer_done <= t_user;
                tmr <= tmr + 1'b1;
                if (tmr == T_RECOV[15:0] - 1'b1) begin tmr <= 16'd0; st <= ret_st; end
            end
            default: st <= ST_PWR;
            endcase

            // 読み出しワード: ユーザへ出す / 調整中は期待値と比較 (余分に読んだ最後の 1 ワードは捨てる)
            if (cap_fire && !(rs == RS_CAP && widx == BL[5:0])) begin
                if (t_user) begin
                    rd_valid <= 1'b1;
                    rd_data  <= cap_word;
                end else if (op != OP_RRD) begin
                    if (((cap_word ^ cal_pat(cap_idx, t_gap)) & CAL_MASK) != 32'd0) cal_ok <= 1'b0;
                end
            end
            if (err_fire) begin
                if (t_user) rd_err <= 1'b1;
                else        cal_ok <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // IO (Gowin ODDR / IDDR / IOBUF)
    // ------------------------------------------------------------------
    assign O_psram_reset_n = {2{rst_n_r}};

    // DQ / RWDS の出力イネーブル。
    //   ODDR の TX → Q1 → IOBUF.OEN の経路は OSS フロー (Apicula 0.33) では実機で効かず、
    //   DQ が一切駆動されなかった (zf3 の実績あるコントローラでも同じ症状を確認)。
    //   そこでファブリックのレジスタから OEN を直接与える。
    //   実機の ODDR の出力はこのレジスタより 1 クロック以上遅れて出てくるので、出力期間を
    //   OE_EXT クロック延長する。延長が足りないと最後のバイトの途中でバスが浮き、直前の値
    //   (前半のデータ) がそのまま取り込まれる (最後に書いたワードの後半が前半と同じ値になった)。
    //   延長分は、読み出しでデバイスが駆動を始める (レイテンシ後) より前に収まる。
    localparam integer OE_EXT = 3;
    reg [OE_EXT:0] dq_oe_sr, rw_oe_sr;
    always @(posedge clk) begin
        dq_oe_sr <= {dq_oe_sr[OE_EXT-1:0], o_dqoe};
        rw_oe_sr <= {rw_oe_sr[OE_EXT-1:0], o_rwoe};
    end
    wire dq_oen = ~|dq_oe_sr;
    wire rw_oen = ~|rw_oe_sr;


    genvar k;
    generate
        for (k = 0; k < 2; k = k + 1) begin : g_die
            if (CK_MODE == 1) begin : g_ck180
                wire unused_clk_p = clk_p;    // このモードでは clk_p を使わない
                // CK: イネーブル中だけ各サイクルの後半 High (立ち上がりが DQ の前半データの中央より T/4 後ろ)
                ODDR u_ck  (.Q0(O_psram_ck[k]),   .Q1(), .D0(1'b0), .D1(o_ck),  .TX(1'b0), .CLK(clk));
                ODDR u_ckn (.Q0(O_psram_ck_n[k]), .Q1(), .D0(1'b1), .D1(!o_ck), .TX(1'b0), .CLK(clk));
            end else begin : g_ckp
                // CK イネーブルを clk_p ドメインへ。clk_p の立ち下がり (clk の 3/4 周期後) で取り込むと、
                // 次の clk_p 立ち上がりで ODDR が拾い、o_cs/o_dq と同じサイクルにそろう
                reg ck_en_p;
                always @(negedge clk_p) ck_en_p <= o_ck;
                // CK: イネーブル中だけ clk_p の前半周期 High。CK# はその反転 (停止中は High)
                ODDR u_ck  (.Q0(O_psram_ck[k]),   .Q1(), .D0(ck_en_p),  .D1(1'b0), .TX(1'b0), .CLK(clk_p));
                ODDR u_ckn (.Q0(O_psram_ck_n[k]), .Q1(), .D0(!ck_en_p), .D1(1'b1), .TX(1'b0), .CLK(clk_p));
            end
            ODDR u_cs  (.Q0(O_psram_cs_n[k]), .Q1(), .D0(o_cs0), .D1(o_cs1), .TX(1'b0), .CLK(clk));

            // RWDS: 書き込み時だけ駆動 (データ中は 0、最後の余分なサイクルは 0/1)、読み出し時は入力
            wire rw_o, rw_i;
            ODDR  u_rw_o (.Q0(rw_o), .Q1(), .D0(o_rwm0), .D1(o_rwm1), .TX(1'b0), .CLK(clk));
            IOBUF u_rw_b (.O(rw_i), .IO(IO_psram_rwds[k]), .I(rw_o), .OEN(rw_oen));
            IDDR  u_rw_i (.Q0(rw_q0[k]), .Q1(rw_q1[k]), .D(rw_i), .CLK(clk));
        end
        for (k = 0; k < 16; k = k + 1) begin : g_dq
            wire dq_o, dq_i;
            ODDR  u_o (.Q0(dq_o), .Q1(), .D0(o_dq0[k]), .D1(o_dq1[k]), .TX(1'b0), .CLK(clk));
            IOBUF u_b (.O(dq_i), .IO(IO_psram_dq[k]), .I(dq_o), .OEN(dq_oen));
            IDDR  u_i (.Q0(dq_q0[k]), .Q1(dq_q1[k]), .D(dq_i), .CLK(clk));
        end
    endgenerate
endmodule
/* verilator lint_on PINCONNECTEMPTY */
