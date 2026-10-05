// 疑似カメラの画素パターン (RGB565)
//   座標ごとに異なる値 + フレーム番号。(0,0) の値 = fid * 0x1111 なので、
//   表示側で先頭画素からフレーム番号を復元できる
function [15:0] cam_pat(input [9:0] px_x, input [8:0] px_y, input [3:0] fid);
    reg [31:0] lin;
    begin
        lin     = px_y * 32'd640 + px_x;
        cam_pat = lin[15:0] * 16'h9E37 + {12'd0, fid} * 16'h1111;
    end
endfunction
