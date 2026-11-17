# ビルドとテスト

[README](../README.md) · [QEMUでの使い方](usage.md)

ビルドにはGNU Make、内蔵LLD付きの [LDC 1.43.0](https://github.com/ldc-developers/ldc/releases/tag/v1.43.0)、EFI用の `lld-link` が必要です。実行には `qemu-system-x86_64` とx86-64用OVMFを使い、アプリのインストールやテストにはPython 3も使用します。対象ホストはmacOSとLinuxです。`make` を実行すると、`build/uefi-esp/` に `EFI/BOOT/BOOTX64.EFI` と `kernel.elf` を生成します。

## 環境ごとの設定

`./configure` は実行環境を検出して `config.mk` を生成し、Makefileはこの設定を読み込んでビルドします。未設定のまま `make` を実行すると、`./configure` の実行を案内して停止します。

```sh
./configure
make run-gui
```

LDCとEFI用リンカーは必須です。LDCは `PATH`、次に `build/tools/ldc2-1.43.0-*/bin/ldc2` を探します。`lld-link` は `PATH`、次にRust同梱のものを探します。QEMU、OVMF、Clangは見つからなくても `config.mk` を生成し、不足している項目を表示します。`./configure` は依存ツールを自動インストールしないため、未検出のツールを使うターゲットを実行する前に各自でパスを設定してください。

パスはコマンドラインオプション、または同名の大文字の環境変数で指定できます。

```sh
./configure --ldc /path/to/ldc2 --lld-link /path/to/lld-link --ovmf-code /path/to/OVMF_CODE.fd
# 環境が変わった場合は再生成する
./configure --force
```

`config.mk` はGitの管理対象外で、既存のファイルは `--force` を指定したときだけ上書きします。`make LDC=/path/to/ldc2` のようにコマンドラインで指定した値は、`config.mk` の設定より優先されます。従来の `Makefile.local` は読み込まないため、独自の設定を追加していた場合は `./configure` のオプションや環境変数へ移行してください。利用可能なオプションの一覧は `./configure --help` で確認できます。

OVMFはQEMUの `../share/qemu/` とLinuxの一般的な配置先から探索します。QEMUの画面表示はmacOSでは `cocoa,zoom-to-fit=on`、その他の環境ではQEMUの既定値になり、`--qemu-display` で変更できます。

## テスト内容

`make test` は普段使う `build/data.img` ではなく使い捨てのディスクを使い、以下の項目を確認します。

- UEFI起動からシェル応答まで、タイマーによるプリエンプション、プロセス障害の隔離とページ回収
- 正常なELFの実行、不正なELFの拒否、仮想メモリの拡張・縮小、メモリ不足時のロールバック
- DlangFS4への保存と再起動後の内容一致、不完全な転送による上書きの防止、破損した世代からの復旧
- DlangFS1〜3の拒否とイメージの保全、DlangFS3を同時接続した状態でのDlangFS4への保存

電卓を含むGUI全体のピクセルテストや操作テスト、暦の単体テスト、個別のD言語機能やPhobosの既知値検証は削除しました。現在はOSの停止、データ喪失、プロセス間の干渉につながるリグレッションを中心に残しています。

標準ランタイムの移植は通常のビルドから分離しています。`make test-druntime` ではC ABI、モジュールの初期化・終了処理、プリエンプション中のTLS隔離、ページ回収を検証します。C側のコンパイルにはClangを使います。詳しくは [移植基盤の手順](druntime.md) を参照してください。

`make phobos-fetch` の後に `make test-phobos` を実行すると、上流Phobosの出力、ストリームエラー、再起動、ページ回収を検証できます。詳しくは [対応範囲と成果物](phobos.md) を参照してください。
