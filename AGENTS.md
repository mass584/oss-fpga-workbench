# AGENTS.md — OSS FPGA 開発環境

すべて OSS のツールチェーンで、macOS (Apple Silicon) / Linux 上で FPGA 開発を行うリポジトリ。
ツールはすべて Nix flake (`flake.nix` + `flake.lock`) で固定され、ホストに必要なのは **Nix と make だけ**。

## クイックスタート

```sh
make setup                 # 初回: flake.lock 生成 + ツールチェーン取得 + バージョン表示
make lint sim              # Verilator lint / Icarus Verilog 自己検証テストベンチ
make                       # = make bitstream (BOARD=tangnano9k PROJECT=blinky)
make detect                # JTAG で FPGA を検出
make prog                  # SRAM へ書き込み (電源断で消える。開発中はこちら)
make flash                 # SPI Flash へ書き込み (永続)
make wave                  # 波形表示 (WAVE_VIEWER=surfer | gtkwave)
make BOARD=icebreaker PROJECT=blinky bitstream   # 別ボード向け
make help                  # ターゲット一覧
```

Nix 未導入なら upstream (LGPL) 版を入れる。sudo のパスワード入力が要るため **通常のターミナルで** 実行すること
(Claude Code の `!` など TTY のない環境では失敗する):

```sh
sh <(curl --proto '=https' --tlsv1.2 -sSfL https://nixos.org/nix/install) --daemon
```

## ツールチェーン

| 用途 | ツール | 備考 |
|---|---|---|
| シミュレーション | Icarus Verilog (`iverilog`/`vvp`) | `-g2012`。テストベンチは `$fatal` で失敗を返す |
| Lint | Verilator (`--lint-only -Wall`) | 警告もエラー扱い。iverilog が見逃す幅不一致などを検出 |
| 波形 | Surfer (既定) / GTKWave | Surfer は macOS ネイティブで軽快 |
| 合成 | Yosys | `synth_gowin` / `synth_ice40` / `synth_ecp5` |
| 配置配線 | nextpnr | Gowin は `nextpnr-himbaechel` (旧 `nextpnr-gowin` は廃止済み) |
| ビットストリーム | Apicula `gowin_pack` / IceStorm `icepack` / Trellis `ecppack` | |
| 書き込み | openFPGALoader | macOS 標準 FTDI ドライバと共存可、追加ドライバ不要 |

確認済みバージョン (2026-10-03, `make versions`): Yosys 0.69, nextpnr 0.11.1, Apicula 0.33,
openFPGALoader 1.1.1, Icarus Verilog 13.0, Verilator 5.052, Surfer 0.7.0, GTKWave 3.3.128。

- バージョン更新は `make update` (= `nix flake update`)。更新後は `make lint sim bitstream` で回帰確認すること。
- ツール追加は `flake.nix` の `packages` に追記。Homebrew や pip でホストに直接入れないこと。
- 対話シェルは `make shell`、または direnv で `.envrc` (`use flake`) を `direnv allow`。
  シェル内では `FPGA_ENV=nix` が立ち、Makefile は `nix develop` を挟まずに直接ツールを呼ぶ。

## ディレクトリ構成

```
flake.nix, flake.lock     ツールチェーン定義とピン留め
Makefile                  共通ターゲット (setup/lint/sim/wave/synth/pnr/bitstream/detect/prog/flash)
mk/arch-<arch>.mk         アーキテクチャ別フロー (gowin, ice40, ecp5)
boards/<board>.mk         ボード定義: ARCH, DEVICE, FAMILY/PACKAGE, OFL_BOARD, CLK_HZ, LED_COUNT
projects/<project>/
  project.mk              TOP, RTL_SRCS, TB_TOP, TB_SRCS (パスはプロジェクトディレクトリ相対)
  rtl/                    合成対象 RTL
  sim/                    テストベンチ
  constr/<board>.cst|pcf|lpf  ボード別ピン制約 (アーキに応じて拡張子が変わる)
build/<project>/<board>/  生成物 (git 管理外)。yosys.log / nextpnr.log もここ
```

### 新しいプロジェクトを追加する

1. `projects/<name>/project.mk` を作り `TOP`, `RTL_SRCS`, `TB_TOP`, `TB_SRCS` を定義。
2. 使うボードごとに `constr/<board>.<cst|pcf|lpf>` を用意。
3. `make PROJECT=<name> lint sim bitstream`。

### 新しいボードを追加する

1. `boards/<board>.mk` を作る。必須: `ARCH`, `DEVICE`, `OFL_BOARD` (`openFPGALoader --list-boards`),
   `CLK_HZ`。Gowin は `FAMILY` (Apicula のファミリ名、例 `GW1N-9C`)、iCE40/ECP5 は `PACKAGE`。
2. 新アーキテクチャなら `mk/arch-<arch>.mk` を追加し、`synth`/`pnr`/`bitstream` ターゲットと
   `BITSTREAM` 変数を定義する。

ボード情報は `-DCLK_HZ=... -DLED_COUNT=...` として RTL に渡る (lint と合成のみ。シミュレーションは
テストベンチがパラメータを明示する)。nextpnr のタイミング目標も `CLK_HZ` から自動設定される。

## 動作確認済みの状態

- **Tang Nano 9K** (GW1NR-LV9QN88PC6/I5, `FAMILY=GW1N-9C`): blinky を合成 → SRAM 書き込み → Flash 書き込み
  まで実機確認済み。JTAG idcode `0x100481b`。USB は VID:PID `0403:6010` (BL702 による FT2232 エミュレーション)、
  `/dev/cu.usbserial-*00` が JTAG、`*01` が UART。
- **iCEBreaker**: ビルドのみ確認 (実機未確認)。ECP5 フロー (`mk/arch-ecp5.mk`) は未検証のテンプレート。

## Tang Nano 9K メモ

- 27 MHz クロック: pin 52 (LVCMOS33)。
- LED ×6: pin 10, 11, 13, 14, 15, 16。**アクティブ Low**、Bank 3 は **1.8 V** (`IO_TYPE=LVCMOS18`)。
- ボタン S1: pin 3, S2: pin 4。アクティブ Low (`PULL_MODE=UP`)。
- UART (BL702 経由): TX pin 17, RX pin 18 (LVCMOS33)。

## エージェント向けルール

- ツールはすべて `make` 経由 (内部で `nix develop --command`) で実行する。ホストの PATH にあるツールに頼らない。
- RTL を変更したら少なくとも `make lint sim` を通すこと。lint の警告は抑制せずに修正するのが原則。
- `make flash` は Flash を書き換える。検証中は `make prog` (SRAM) を使い、永続化が必要なときだけ `flash` を使う。
- git 管理にした場合、Nix flake は **git に追加されたファイルしか見えない**。`flake.nix` を変えたら
  `git add` してから `make` すること。
- Makefile は macOS 標準の GNU Make 3.81 でも動くように書く (`.ONESHELL` や `$(file ...)` などは使わない)。
