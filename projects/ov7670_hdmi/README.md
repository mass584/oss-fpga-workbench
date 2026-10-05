# ov7670_hdmi — OV7670 → HDMI カメラモニタ + BME280 表示 (Tang Nano 9K)

OV7670 (FIFO なし) の VGA 映像を、GW1NR-9C 内蔵 PSRAM をトリプルバッファにして 640x480@60Hz の
DVI (HDMI) にフル解像度で表示し、BME280 の温度・湿度・気圧を画面右上に重ねる。OSS フロー
(Yosys / nextpnr / Apicula) のみ。

```sh
make PROJECT=ov7670_hdmi lint sim          # Verilator lint + 全テストベンチ (システム試験は数十分かかる)
make PROJECT=ov7670_hdmi                   # ビットストリーム (RGB565, 15fps)
make PROJECT=ov7670_hdmi prog              # SRAM へ書き込み
make PROJECT=ov7670_hdmi TB_TOPS=tb_calc sim   # テストベンチを選んで実行

# 設計の切り替え (変更後は make clean)
make PROJECT=ov7670_hdmi EXTRA_DEFINES="-DCAM_YUV -DCAM_SLOW" clean bitstream
```

| define | 内容 |
|---|---|
| (なし) | RGB565, 15fps。カメラ内の RGB 変換で輪郭に色の縁取り (ハロー) が出る |
| `-DCAM_YUV` | YUV422 で受けて FPGA (`yuv2rgb.v`) で RGB に変換する。ハローが出ない。S2 で彩度を切り替え |
| `-DCAM_SLOW` | カメラを 7.5fps (PCLK 6.3MHz) にする。ブレッドボード配線では YUV を 15fps で取り込めない |
| `-DCAM_NO_HOLDOFF` | PCLK のグリッチを捨てない (`cam_sync.v`)。基板の信号品質の評価用 |
| `-DCAM_DEBUG` | UART にカメラ取り込みの統計を出す。FPGA に収まらないので BME280 は入らない |
| `-DCAM_TESTBAR` | カメラにカラーバーを出させる (取り込み経路の切り分け) |

## 構成

```
 clk_mem 45MHz                                                          clk_pix 25.2MHz
 cam_frontend ─► psram_fb ◄──► psram_ctrl ◄──► 内蔵 PSRAM (2 ダイ x8)
 ├ cam_sync     (書き込み/読み出し/アービタ/
 ├ cam_capture   トリプルバッファ)
 ├ cam_pack            └─► dpram (ラインバッファ 2 面) ─► fb_display ─► text_overlay ─► dvi_tx
 └ async_fifo                                            (yuv2rgb)      ▲ (右上に 3 行 x 9 文字)
 bme280_env (i2c_master, env_calc) ── 表示文字 ─────────────────────────┘
```

| ファイル | 内容 |
|---|---|
| `rtl/top.v` | トップ。部品のつなぎと LED |
| `rtl/clocks.v` | PLL 2 個 (126MHz/25.2MHz, 45MHz/45MHz 90°) とリセット同期 |
| `rtl/cam_frontend.v` | カメラ取り込み経路 (下の 4 つ) |
| `rtl/cam_sync.v` | PCLK/VSYNC/HREF/D を clk_mem の IDDR でオーバーサンプルし、PCLK の立ち上がりで `ce` を出す |
| `rtl/cam_capture.v` | 640x480 全画素 + `sof`。短いラインは 0 で埋める |
| `rtl/cam_pack.v` | 2 画素を 1 エントリ `{sof, 偶数, 奇数}` に。フレーム末でバースト境界まで詰める |
| `rtl/async_fifo.v` | グレイコードポインタの非同期 FIFO (FWFT) |
| `rtl/psram_ctrl.v` | PSRAM コントローラ (自作, HyperBus 系, 2 ダイ並列 x16, 自己調整) |
| `rtl/psram_fb.v` | 書き込み/読み出し/アービタ/トリプルバッファ |
| `rtl/fb_display.v` | ライン要求・先読み・アンダーラン検出・ラインバッファからの画素出力 |
| `rtl/yuv2rgb.v` | BT.601 フルレンジの YUV → RGB (CAM_YUV)。シフト加算, 3 段 |
| `rtl/bme280_env.v`, `i2c_master.v` | BME280 を I2C で 1 秒ごとに読む |
| `rtl/env_calc.v`, `env_prog.v` | 補正計算と表示文字の生成 (マイクロコード実行器と、その ROM) |
| `rtl/text_overlay.v`, `env_font.v`, `ov_delay.v` | 文字の重ね描き (5x7 フォントを 3 倍) |
| `rtl/dbg_uart.v`, `dbg_report.v`, `uart_tx.v` | UART の状態表示 |
| `rtl/cam_probe.v`, `cam_runlen.v`, `cam_monitor.v` | 取り込み統計 (CAM_DEBUG のみ) |
| `rtl/ov7670_sccb_init.v`, `ov7670_regs.v` | SCCB でのカメラ設定とレジスタ表 |
| `rtl/video_timing.v`, `tmds_encoder.v`, `dvi_tx.v` | 640x480@60Hz の DVI 出力 |
| `rtl/btn_debounce.v`, `cdc_sync.v`, `dpram.v` | 共通部品 |
| `tools/env_asm.py` | `env_prog.v` / `env_font.v` / `sim/env_vectors.vh` を生成する (下記) |

## 配線 (Tang Nano 9K)

| 信号 | ピン | 備考 |
|---|---|---|
| カメラ D7..D0 | 39, 25, 26, 27, 28, 29, 30, 33 | |
| HREF / VSYNC / PCLK | 34 / 40 / 35 | |
| XCLK | 38 | 25.2MHz を出す。PCLK の隣から離すため PWDN の位置に置いた |
| SIO-C / SIO-D | 36 / 37 | |
| RESET | 42 | |
| (41) | 41 | 常に Low。PCLK の線に沿わせてカメラの GND につなぐガード線 |
| カメラ PWDN | — | GND に直結 |
| BME280 SDA (SDI) / SCL (SCK) | 48 / 49 | I2C アドレス 0x76 (SDO=GND)。CSB は 3.3V (I2C モード) |
| ボタン S1 / S2 | 4 / 3 | リセット / 彩度 (CAM_YUV) |

pin 33〜42 は RGB LCD コネクタ、36〜39 は TF カードと共用 (LCD は外し、TF カードは挿さない)。
カメラの STROBE は使わない (開放)。

## カメラの取り込み (`cam_sync.v`)

PCLK をクロックとして使わず、clk_mem (45MHz) の IDDR で両エッジ (実効 90MS/s) でサンプルし、
PCLK の立ち上がりを見つけたサイクルで `ce` を出す。OSS フローでは pin 35 (GCLKT_4) からグローバル網へ
入れられず、一般配線のクロックは hold 違反、DQCE 経由は実機で動かなかったため。

- 立ち上がり = Low (1 サンプル以上) の後に High が 2 サンプル以上続く位置。
- **ホールドオフ**: 前の立ち上がりから 5 サンプル (55ns) 以内の立ち上がりは捨てる。ブレッドボード配線では
  PCLK の High の途中に約 11ns の落ち込みが周期の 3 割ほど乗り、余分な立ち上がりと数えて RGB565 の
  バイトの組がずれ、行の途中から右端まで横筋が出ていた。本物の Low も約 20ns と短く 1 サンプルしか
  取れないことがあるので、波形の形ではなく時間で区別している。**本来は基板の信号品質で直すべきもの**で、
  ロジックは安全網。`-DCAM_NO_HOLDOFF -DCAM_DEBUG` で補正なしの品質を評価できる。
- データは立ち上がりのサンプルで取る (実機で ±1〜2 サンプルずらすとどれも悪化した)。
- 条件: PCLK の High が 22ns 以上、Low が 11ns 以上、周期 55ns 超 (PCLK < 18MHz)。

### 実機での調査の記録

- 駆動力 (COM2) を 4x から 1x に下げると、エッジが鈍ってしきい値付近でばたつき大幅に悪化した。
- FPGA 入力のヒステリシス: `HIGH` は余分な立ち上がりを 0 にしたが Low が短くなり取りこぼしが増えた。
  `L2H` は High に届かずエッジの約半分を取りこぼした。XCLK を pin 38 に移した構成では、PCLK (35) に
  ヒステリシスを付けるとカメラが止まる (Apicula が 38 の設定を壊していると思われる)。使っていない。
- GND を足す (本物の GND + pin 41 のガード線) と取りこぼしが 0 になった。
- YUV は Y と U/V が 1 バイトごとに交互に来てデータ線の切り替わりが多く、15fps では PCLK が乱れて
  取りこぼす (ブレッドボード)。7.5fps なら全行正しく取れる。
- 等高線状の色の点は、7.5fps でもサンプル位置を変えても変わらず、YUV で受けると消えた
  (OV7670 内の RGB565 変換が原因)。

## BME280 の表示

`bme280_env` が起動時に ctrl_hum=0x01, ctrl_meas=0x27 (温度/気圧 x1, ノーマル), config=0xA0 を書き、
品番 (0xD0) と補正係数 (0x88..0xA1, 0xE1..0xE7) を読む。以後 1 秒ごとに測定値 (0xF7..0xFE) を読み、
`env_calc` がデータシートの整数の補正式で温度 [0.01℃]・気圧 [Pa]・湿度 [%RH/1024] を求めて
表示文字 (`  23.4oC ` / `  45.6%  ` / `1005.2hPa`) を作る。BMP280 (品番 0x58) は湿度を `--.-` にし、
応答しない・品番が違うときは全部 `--.-` にする。

`env_calc` は小さなマイクロコード実行器 (32bit レジスタ 16 本, 乗除算は 1 ビットずつ)。
プログラムは `tools/env_asm.py` に Python で書き、データシートの C コードをそのまま写した参照実装と
命令シミュレータの結果を突き合わせてから ROM を生成する:

```sh
cd projects/ov7670_hdmi && python3 tools/env_asm.py   # env_prog.v / env_font.v / sim/env_vectors.vh を再生成
```

## PSRAM コントローラ (`psram_ctrl.v`)

Gowin 純正 IP (PSRAM Memory Interface HS) は OSS フローで使えないので自作した。
Apicula は GW1NR-9C の内蔵 PSRAM ピンを `O_psram_ck/ck_n/cs_n/reset_n[1:0]`, `IO_psram_dq[15:0]`, `IO_psram_rwds[1:0]`
というポート名で自動配置する (cst 不要)。

- 2 ダイに同じ CK/CS#/CA を与えて並列動作。`dq[15:8]`=ダイ1, `dq[7:0]`=ダイ0。1 クロックで 2 画素。
- CK は clk_mem を 90° 遅らせた clk_mem_p で ODDR から出す。DQ/CS# は clk_mem の ODDR。
- CR0 は書かない (実機で書き込み結果が不正だったため)。既定の固定レイテンシ 6 で使う。
- **書き込みレイテンシの自動調整**: 起動時に CA 後のクロック数 gap を 3〜14 で順に試し、書いて読み戻して
  一致した値を使う (実機は gap 11)。実機では各バイトの bit7 が書き込めないので比較から除く (`CAL_MASK`)。
- **読み出しの自動整列**: RWDS が「CA 中 High → レイテンシ中 Low → トグル」と変化するのを見て、データの先頭と半周期位相を決める。
- 全候補で失敗したらやり直し続ける (LED3 点滅)。
- 起動時に ID0 と CR0 を読む (値は使わない。実機で調整が通っている初期化の手順を変えないために残している)。

### メモリマップと帯域

- アドレスはダイ内 16bit ワード。1 ワード = 2 画素。バッファ b の先頭 = `b * 0x40000`。1 フレーム 153,600 ワード。調整用 `0x1C0000`。
- バーストは 16 ワード (32 画素) で 16 ワード境界に揃える (実機のデバイスは 16 ワードで折り返す)。

### トリプルバッファ

状態 (disp / latest / wr) はすべて clk_mem ドメインに置き、表示側とは「ライン要求」「垂直ブランク開始」「ライン完了」のイベント (トグル + 値保持、2FF 同期) だけをやり取りする。

- 書き込みが 1 フレーム完了 → `latest <= wr`、`wr <= 残りの 1 面` (常に disp, latest と異なる)
- 表示側の垂直ブランク開始 (y=480) → `disp <= latest`
- SOF で書き込み位置を先頭に戻す。途中で崩れたフレームは完成扱いにせず同じ面に書き直す。

## 状態表示

LED (負論理): 0 = PLL ロック, 1 = SCCB 設定完了, 2 = カメラフレームごとに反転,
3 = PSRAM 初期化完了 (調整失敗中は点滅), 4 = アンダーラン (スティッキー), 5 = PSRAM へのフレーム書き込みごとに反転。
立ち上げ順: LED0 → LED3 → LED1 (約 170ms 後) → LED2/LED5 が点滅 → 映像。

UART (BL702 経由の `/dev/cu.usbserial-*1`, 115200 8N1, 1 秒ごと):

```
U=0008 RC=01 S=1 G=B FW=7B E=1 SA=0 | BM=60:0:08
```

| 項目 | 内容 |
|---|---|
| U / RC | 起動後の秒数 / リセット回数 |
| S / G | {調整失敗あり, PSRAM 初期化完了} / 書き込み gap |
| FW | PSRAM に書けたフレーム数 (1 秒に 15 前後増えれば正常) |
| E | {アンダーラン, 読み出しエラー, SOF 異常, FIFO あふれ (初期化前を含む)}。スティッキー |
| SA | CAM_YUV の彩度の段階 (0..4 = x1.0..x2.0) |
| BM | BME280 {品番 60/58, 通信エラー, 測定値を読めた回数} |

`-DCAM_DEBUG` のときの追加項目は `rtl/dbg_uart.v` の先頭のコメントを参照。基板の評価では
`-DCAM_YUV -DCAM_NO_HOLDOFF -DCAM_DEBUG` で、`LB=` の 2 番目 (バイト数が合わないライン) と `CI=` の先頭
(余分な立ち上がり) が 0 なら、ロジックの補正なしで取り込めている。

## 検証

| テストベンチ | 内容 |
|---|---|
| `tb_tmds` | TMDS エンコード→デコード往復一致、制御トークン、running disparity |
| `tb_sccb` | SCCB 波形をデコードしてレジスタ表と一致 |
| `tb_capture` | 書き込みアドレス・データ・SOF、途中打ち切りフレーム後の回復 |
| `tb_dbg` | UART 出力がテンプレートどおり |
| `tb_probe` | 取り込み異常の検出と集計 |
| `tb_csync` | グリッチ入りの PCLK で立ち上がりを 1 回ずつ数え、データを取りこぼさない |
| `tb_yuv` | YUV → RGB が BT.601 の式と ±1 以内 (彩度 x1.0 / x2.0) |
| `tb_calc` | BME280 の補正計算が参照実装と一致 (室温・氷点下・低気圧・湿度 0・BMP280・エラー) |
| `tb_env` / `tb_env_nack` | BME280 モデルとの I2C 通し試験 / センサが応答しない場合 |
| `tb_overlay` | 文字の重ね描きの 1 フレーム全画素 (映像の遅れ 1 / 4 クロック) |
| `tb_psram` | tCKD 1〜7ns × CK 位相の 7 構成で gap 自動調整とランダムバースト読み書き |
| `tb_top_fast` / `tb_top_slow` | システム全体。PCLK 15.6MHz / 12.6MHz (+ 途中打ち切りフレーム) |

システム試験は疑似カメラ (`sim/ov7670_model.v`) と PSRAM モデル x2 を `top` に繋ぎ、dvi_tx 手前の画素を全画素検査する
(各表示フレームが 1 枚のカメラフレームと一致 = ティアリングなし、フレームが更新される、アンダーラン・
読み出しエラー・FIFO あふれ・書き込み中バッファの読み出しがない)。cam_sync の条件から PCLK は 18MHz 未満なので、
カメラは表示 (60Hz) より必ず遅い。BME280 の表示は切る (`ENV_OVERLAY=0`)。

## 既知の注意点 (ツール)

- Apicula 0.33 の `gowin_pack` は GW1N-9C の左側 rPLL を使うと落ちる (PLL 2 個で必ず当たる)。`nix/apycula-pll-offx.patch` を当てている。
- Apicula 0.33 の `gowin_pack` は DSP (MULT9X9) の属性を扱えず落ちる。乗算はすべてシフト加算か逐次で書く (`*` を使わない)。
- nextpnr の HeAP 配置は、LUT と ALU の合計が 8640 に近いと「配置できない」で止まる (ALU も LUT の場所を使う)。
  リソースの表示は LUT4 と ALU を足して見ること。デバッグ用のカウンタ群を `-DCAM_DEBUG` に分けたのはこのため。
- `env_prog` の ROM を BSRAM に置くと、pc → アドレス入力で nextpnr のホールド違反が出たので LUT に置いている。
- `clk_mem` (と配置によっては `clk_ser`) が専用配線に乗らない警告が出るが、実機では問題なく動いている。
- SDC は nextpnr 用 `constr/tangnano9k_nextpnr.sdc` を使う (`tangnano9k.sdc` は Gowin EDA 用の参考)。
- nextpnr は `IO_LOC "x" 71,70;` の 2 ピン形式で差動の n 側を配置しないので、p/n を別々に指定している。
