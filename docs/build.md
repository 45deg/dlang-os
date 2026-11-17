# ビルドとテスト

[README](../README.md) · [QEMUでの使い方](usage.md)

GNU Make、内蔵LLD付きの [LDC 1.43.0](https://github.com/ldc-developers/ldc/releases/tag/v1.43.0)、EFI用の `lld-link` が必要です。実行には `qemu-system-x86_64` とx86-64用OVMF、アプリのインストールとテストには Python 3 も使います。対象ホストはmacOS/Linuxです。`make` は `build/uefi-esp/` に `EFI/BOOT/BOOTX64.EFI` と `kernel.elf` を生成します。

## 環境ごとの設定

`./configure` が環境を検出して `config.mk` を生成します。Makefileはこの設定を読み込んでビルドします。未設定の場合は `./configure` の実行を案内して停止します。

```sh
./configure
make run-gui
```

LDCとEFI用リンカーは必須です。LDCはPATH、次に `build/tools/ldc2-1.43.0-*/bin/ldc2` を探します。`lld-link` はPATH、次にRust同梱のものを探します。QEMU、OVMF、Clangは検出できなくても設定を生成し、不足項目を表示します。それらを使うターゲットの実行前に設定してください。依存ツールのインストールは行いません。

パスはオプションまたは同名の大文字環境変数で指定できます。

```sh
./configure --ldc /path/to/ldc2 --lld-link /path/to/lld-link --ovmf-code /path/to/OVMF_CODE.fd
# 環境が変わった場合は再生成する
./configure --force
```

`config.mk` はGit管理外です。既存ファイルは `--force` を指定したときだけ上書きします。`make LDC=/path/to/ldc2` のようなコマンドライン指定は生成設定より優先されます。以前の `Makefile.local` は読み込みません。そこに独自設定を追加していた場合は、configureのオプションや環境変数へ移してください。利用可能なオプションは `./configure --help` で確認できます。

OVMFはQEMUの `../share/qemu/` とLinuxの一般的な配置先を探します。macOSの表示は `cocoa,zoom-to-fit=on`、その他はQEMUの既定値です。`--qemu-display` で変更できます。

## 残すテスト

`make test` は使い捨てディスクで以下を確認します。普段の `build/data.img` は使いません。

- UEFI起動からシェル応答、タイマによるプリエンプト、プロセス障害の隔離とページ回収。
- 正常なELFの実行、不正ELFの拒否、VMの拡張・縮小・メモリ不足時のロールバック。
- DlangFS4の保存と再起動後の内容一致、不完全な転送による上書きの防止、破損世代からの復旧。
- DlangFS1〜3の拒否とイメージの保全、DlangFS3と同時接続したDlangFS4への保存。

電卓を含むGUI全体のピクセル・操作テスト、暦の単体テスト、個別のD言語機能やPhobosの既知値検証は削除しました。OS停止、データ喪失、プロセス間の干渉につながる回帰を中心に残しています。

標準ランタイムの移植は通常のビルドから分離しています。`make test-druntime` はC ABI、モジュールの初期化・終了、プリエンプト中のTLS隔離とページ回収を検証します。C側にはClangを使います。[移植基盤の手順](druntime.md)を参照してください。

`make phobos-fetch` の後、`make test-phobos` で上流Phobosの出力、ストリームエラー、再起動とページ回収を検証できます。[対応範囲と成果物](phobos.md)を参照してください。
