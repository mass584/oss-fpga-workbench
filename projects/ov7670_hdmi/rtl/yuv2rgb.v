// ============================================================================
// YUV (YCbCr, BT.601 フルレンジ 0..255) -> RGB888 変換 (3 段パイプライン, レイテンシ 3clk)
//   R = Y + 1.402 (V-128)
//   G = Y - 0.344 (U-128) - 0.714 (V-128)
//   B = Y + 1.772 (U-128)
//   係数は 256 倍の整数 (359, 88, 183, 454)。定数乗算はシフト加算で書く (DSP を使わない)
//   sat: 彩度 (U-128, V-128 に掛ける倍率, 1/4 単位。4 = 1.0)。色差は ±255 に飽和
//   OV7670 の RGB565 出力 (センサ内の変換) は明るい面に等高線状の色の点が出たので、
//   YUV422 で受けてここで変換する (CAM_YUV)
// ============================================================================
module yuv2rgb (
    input  wire       clk,
    input  wire [7:0] y,
    input  wire [7:0] u,
    input  wire [7:0] v,
    input  wire [3:0] sat,
    output reg  [7:0] r,
    output reg  [7:0] g,
    output reg  [7:0] b
);
    // 段 1: 色差を符号付きにして彩度を掛ける
    reg signed [9:0] du, dv;
    wire signed [8:0]  du0 = $signed({1'b0, u}) - 9'sd128;
    wire signed [8:0]  dv0 = $signed({1'b0, v}) - 9'sd128;
    // 可変の乗算はシフト加算で書く (`*` だと MULT9X9 に割り当てられ、Apicula 0.33 の gowin_pack が
    // DSP の属性 IRBY_IREG0BL_0 を知らずに落ちる)
    function signed [13:0] mul_sat(input signed [8:0] x, input [3:0] k);
        reg signed [13:0] xe;
        begin
            xe = {{5{x[8]}}, x};
            mul_sat = (k[3] ? (xe <<< 3) : 14'sd0) + (k[2] ? (xe <<< 2) : 14'sd0)
                    + (k[1] ? (xe <<< 1) : 14'sd0) + (k[0] ? xe : 14'sd0);
        end
    endfunction
    wire signed [13:0] dum = mul_sat(du0, sat);
    wire signed [13:0] dvm = mul_sat(dv0, sat);
    function signed [9:0] lim(input signed [11:0] x);      // ±255 に飽和
        lim = (x > 12'sd255) ? 10'sd255 : (x < -12'sd255) ? -10'sd255 : x[9:0];
    endfunction
    reg        [7:0] y1;
    // 段 2: 係数を掛ける (19bit 符号付き)
    reg signed [18:0] tr, tg, tb;
    reg        [7:0]  y2;

    wire signed [18:0] du_x = {{9{du[9]}}, du};
    wire signed [18:0] dv_x = {{9{dv[9]}}, dv};
    wire signed [18:0] mr  = (dv_x <<< 8) + (dv_x <<< 6) + (dv_x <<< 5) + (dv_x <<< 2) + (dv_x <<< 1) + dv_x;           // 359 dv
    wire signed [18:0] mgu = (du_x <<< 6) + (du_x <<< 4) + (du_x <<< 3);                                               //  88 du
    wire signed [18:0] mgv = (dv_x <<< 7) + (dv_x <<< 5) + (dv_x <<< 4) + (dv_x <<< 2) + (dv_x <<< 1) + dv_x;           // 183 dv
    wire signed [18:0] mb  = (du_x <<< 8) + (du_x <<< 7) + (du_x <<< 6) + (du_x <<< 2) + (du_x <<< 1);                 // 454 du

    // 段 3: Y を足して四捨五入し、0..255 に飽和
    // 四捨五入して 1/256 (上位 11bit を取る = 算術シフト。|値| <= 454*255/256 = 453 なので 11bit に収まる)
    wire signed [18:0] rr  = tr + 19'sd128;
    wire signed [18:0] rg  = tg + 19'sd128;
    wire signed [18:0] rb  = tb + 19'sd128;
    wire signed [10:0] ys  = $signed({3'b000, y2});
    wire signed [10:0] sr  = ys + $signed(rr[18:8]);
    wire signed [10:0] sg  = ys - $signed(rg[18:8]);
    wire signed [10:0] sb  = ys + $signed(rb[18:8]);
    wire unused_ok = &{1'b0, rr[7:0], rg[7:0], rb[7:0], dum[1:0], dvm[1:0]};   // 切り捨てる端数

    function [7:0] clamp(input signed [10:0] s);
        clamp = (s < 0) ? 8'd0 : (s > 11'sd255) ? 8'd255 : s[7:0];
    endfunction

    always @(posedge clk) begin
        du <= lim($signed(dum[13:2]));
        dv <= lim($signed(dvm[13:2]));
        y1 <= y;

        tr <= mr;
        tg <= mgu + mgv;
        tb <= mb;
        y2 <= y1;

        r <= clamp(sr);
        g <= clamp(sg);
        b <= clamp(sb);
    end
endmodule
