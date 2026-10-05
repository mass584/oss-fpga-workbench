# ov7670_hdmi — OV7670 → HDMI カメラモニタ (Tang Nano 9K)

OV7670 (FIFO なし) の VGA RGB565 映像を、GW1NR-9C 内蔵 PSRAM をトリプルバッファにして
640x480@60Hz の DVI (HDMI) にフル解像度で表示する。OSS フロー (Yosys / nextpnr / Apicula) のみ。

```sh
make PROJECT=ov7670_hdmi lint sim          # Verilator lint + 全テストベンチ (システム試験は数分かかる)
make PROJECT=ov7670_hdmi                   # ビットストリーム
make PROJECT=ov7670_hdmi prog              # SRAM へ書き込み
make PROJECT=ov7670_hdmi TB_TOPS=tb_psram sim   # テストベンチを選んで実行

# Phase 1 (160x120 を BSRAM に保存して 4 倍拡大) に戻す
make PROJECT=ov7670_hdmi EXTRA_DEFINES=-DFB_PHASE1 clean bitstream
```

## 構成 (Phase 2)

```
 pclk (DQCE)              clk_mem 63MHz                              clk_pix 25.2MHz
 cam_capture ─► cam_pack ─► async_fifo ─► psram_fb ◄──► psram_ctrl ◄──► 内蔵 PSRAM (2 ダイ x8)
 (640x480)     (2画素/entry  (512x33,       │ writer / reader / arbiter (読み出し優先)
               +SOF, 境界   グレイコード,   │ トリプルバッファ管理
               揃えの詰め物) FWFT)          └─► dpram (ラインバッファ 2面) ─► fb_display ─► dvi_tx
```

| ファイル | 内容 |
|---|---|
| `rtl/top.v` | トップ。`FB_PHASE1` で Phase 1 構成に切り替え |
| `rtl/cam_capture.v` | `DECIMATE=0` で全画素出力 + `sof` (Phase 1 は `DECIMATE=1`) |
| `rtl/cam_pack.v` | 2 画素を 1 エントリ `{sof, 偶数, 奇数}` に。フレーム末で 32 エントリ境界まで詰める |
| `rtl/async_fifo.v` | グレイコードポインタの非同期 FIFO (FWFT) |
| `rtl/psram_ctrl.v` | PSRAM コントローラ (自作, HyperBus 系, 2 ダイ並列 x16, 自己調整) |
| `rtl/psram_fb.v` | 書き込み/読み出し/アービタ/トリプルバッファ (メモリクロックドメイン) |
| `rtl/fb_display.v` | ライン要求・先読み・アンダーラン検出・ラインバッファからの画素出力 |
| `rtl/cdc_sync.v`, `rtl/dpram.v` | 2FF 同期 / デュアルクロック RAM |
| `rtl/framebuf.v` | Phase 1 用 160x120 BSRAM (Phase 2 では不使用) |
| `rtl/video_timing.v`, `tmds_encoder.v`, `dvi_tx.v`, `ov7670_sccb_init.v`, `ov7670_regs.v` | Phase 1 から流用 |

### メモリマップと帯域

- アドレスはダイ内 16bit ワード。1 ワード = 2 画素 (2 ダイ x 2 バイト)。1 クロックで 1 ワード。
- バッファ b の先頭 = `b * 0x40000` (2 ダイ合計 1MB 刻み)。1 フレーム 153,600 ワード (614,400B)。調整用 `0x1C0000`。
- バーストは 32 ワード (64 画素) で 32 ワード境界に揃える → 行 (1KB) 境界をまたがない。CS# Low は最長約 100 クロック (1.6µs < tCSM 4µs)。
- 1 バースト約 45〜55 クロック。1 ライン表示期間 (31.7µs = 約 2000 クロック) に、読み出し 10 バースト ≒ 530 クロック + 書き込み (15fps で約 3 バースト)。30fps でも余裕がある。

### トリプルバッファ

状態 (disp / latest / wr) はすべて clk_mem ドメインに置き、表示側とは「ライン要求」「垂直ブランク開始」「ライン完了」のイベント (トグル + 値保持、2FF 同期) だけをやり取りする。

- 書き込みが 1 フレーム完了 → `latest <= wr`、`wr <= 残りの 1 面` (常に disp, latest と異なる)
- 表示側の垂直ブランク開始 (y=480) → `disp <= latest`
- SOF で書き込み位置を先頭に戻す。途中で崩れたフレームは完成扱いにせず同じ面に書き直す。

## PSRAM コントローラ (`psram_ctrl.v`)

Gowin 純正 IP (PSRAM Memory Interface HS) は OSS フローで使えないので自作した。
Apicula は GW1NR-9C の内蔵 PSRAM ピンを `O_psram_ck/ck_n/cs_n/reset_n[1:0]`, `IO_psram_dq[15:0]`, `IO_psram_rwds[1:0]`
というポート名で自動配置する (cst 不要)。

- 2 ダイに同じ CK/CS#/CA を与えて並列動作。`dq[15:8]`=ダイ1, `dq[7:0]`=ダイ0。
- CK は clk_mem を 90° 遅らせた clk_mem_p で ODDR から常時出力 (CS# で区切る)。DQ/CS# は clk_mem の ODDR。
- CR0 = `0x8FEF` (初期レイテンシ 3, 固定レイテンシ) を最初に書く。
- **書き込みレイテンシの自動調整**: 起動時に CA 後のクロック数 gap を 3〜14 で順に試し、書いて読み戻して一致した値を使う。
  CR0 が効いていなくても (既定レイテンシ 6 → gap 11) 動く。
- **読み出しの自動整列**: RWDS が「CA 中 High → レイテンシ中 Low → トグル」と変化するのを見て、データの先頭と半周期位相を決める。
- 全候補で失敗したら CR0 からやり直し続ける (LED3 点滅)。

### 実機で未確認の点 (シミュレーションモデルの仮定)

HyperBus の一般的な仕様に沿って書いたが、実機の PSRAM のタイミングは未確認。違った場合に調整する場所:

| 項目 | 現在の値 | 調整場所 |
|---|---|---|
| CK の位相 (データ中央に CK エッジ) | 90° | `top.v` u_pll_mem `PSDA_SEL` (22.5° 刻み) |
| CR0 (レイテンシ 3 固定) | `16'h8FEF` | `psram_ctrl` パラメータ `CR0` |
| 書き込み gap 探索範囲 | 3〜14 | `G_MIN` / `G_MAX` |
| 読み出しのサンプル | IDDR を clk_mem でサンプル、RWDS で整列 | CK 位相で窓の位置が動く |
| CK フリーラン | CS# High 中も CK をトグル | HyperBus では許容とされるが要確認 |

## デバッグ LED (負論理)

| LED | Phase 2 | Phase 1 |
|---|---|---|
| 0 | PLL ロック (2 個とも) | PLL ロック |
| 1 | SCCB 設定完了 | SCCB 設定完了 |
| 2 | カメラフレームごとに反転 | 同左 |
| 3 | PSRAM 初期化 (調整) 完了。調整失敗中は点滅 | — |
| 4 | アンダーラン検出 (スティッキー、リセットで解除) | — |
| 5 | PSRAM へのフレーム書き込み完了ごとに反転 | — |

実機の立ち上げ順: LED0 点灯 → LED3 点灯 (PSRAM OK) → LED1 点灯 (約 170ms 後) → LED2/LED5 が点滅 → 映像。
LED3 が点滅のままなら PSRAM の読み書きが通っていない (上の表の CK 位相を変えて試す)。

## 検証

| テストベンチ | 内容 |
|---|---|
| `tb_tmds` | TMDS エンコード→デコード往復一致 (16 万語)、制御トークン、running disparity ±10 以内 |
| `tb_sccb` | SCCB 波形をモニタして 20 個の書き込みをデコード、レジスタ表と一致、SIOC High 中の SIOD 変化なし |
| `tb_capture` | `DECIMATE=0/1` の書き込みアドレス・データ・SOF、途中打ち切りフレーム後の回復 |
| `tb_psram` | tCKD 1〜7ns × CK 位相 67.5〜112.5° の 7 構成で gap 自動調整、ランダムバースト読み書き一致、モデルの違反なし |
| `tb_top_fast` | システム全体。カメラ約 13ms/フレーム (表示より速い) |
| `tb_top_slow` | システム全体。カメラ約 26ms/フレーム (表示より遅い) + 2 枚目を途中で打ち切り |

システム試験は疑似カメラ (`sim/ov7670_model.v`) と PSRAM モデル (`sim/psram_model.v`) x2 を `top` に繋ぎ、
dvi_tx 手前の画素を全画素検査する: 各表示フレームが 1 枚のカメラフレームと完全一致すること (ティアリングなし)、
フレームが更新されていくこと、アンダーラン・読み出しエラー・FIFO あふれ・書き込み中バッファの読み出しがないこと。
Gowin プリミティブは `sim/gowin_sim_models.v` の振る舞いモデル。

## SPEC からの変更点

- **ツール**: Gowin EDA + 純正 PSRAM IP ではなく OSS フロー + 自作コントローラ (リポジトリの方針)。
  SDC は nextpnr 用 `constr/tangnano9k_nextpnr.sdc` を使う (`tangnano9k.sdc` は Gowin EDA 用の参考)。
- **FIFO 幅**: 16bit ではなく 33bit (2 画素 + SOF)。PSRAM は 1 クロック 2 画素なので、16bit だと読み出しが追いつかず
  バースト分のステージングバッファが要る。深さ 512 エントリ = 1024 画素。
- **SOF の受け渡し**: FIFO の 33bit 目。`cam_pack` がフレーム末で 32 エントリ境界まで詰め、SOF を必ずバースト先頭に置く。
- **cam_capture**: 間引きを `DECIMATE` パラメータにし、Phase 1 の動作も残した。
- **PCLK**: pin 35 (GCLKT_4) からの専用クロック経路を nextpnr が使えず、一般配線のスキューで hold 違反が出る。
  `DQCE` (CE=1) を挟んでグローバル網で配線させている。
- **cst**: nextpnr は `IO_LOC "x" 71,70;` の 2 ピン形式で差動の n 側を配置しないので、p/n を別々に指定。
- **ov7670_sccb_init.v**: 動作は変えず、幅の警告修正とレジスタ表 (`ov7670_regs.v`) の別ファイル化のみ。

## 既知の注意点

- nextpnr のリソース表示で `DQCE: 25/24 (104%)` と出るが、配線は成功しグローバル網で配線されている (nextpnr の集計上の表示)。
- Phase 1 は既定シードだと clk_ser→CLKDIV が専用配線に乗らない配置になることがあるため、`--seed 2` を固定している。
- Apicula 0.33 の `gowin_pack` は GW1N-9C の左側 rPLL を使うと落ちる (PLL 2 個使用で必ず当たる)。
  `nix/apycula-pll-offx.patch` を flake で当てている。
