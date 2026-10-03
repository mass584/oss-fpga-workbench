# oss-fpga-workbench

OSS ツールチェーンだけで FPGA を開発する環境。Nix で全ツールを固定し、macOS / Linux で再現可能。

## 使い方

```sh
make setup   # 初回のみ (要 Nix)
make sim     # シミュレーション
make         # ビットストリーム生成
make prog    # SRAM に書き込み (一時)
make flash   # Flash に書き込み (永続)
```

`make BOARD=<board> PROJECT=<project>` で切り替え。詳細は [AGENTS.md](AGENTS.md)。

## 対応ボード

- Sipeed Tang Nano 9K (実機確認済み)
- iCEBreaker (ビルドのみ)
