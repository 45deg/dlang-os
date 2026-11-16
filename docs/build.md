# ビルドとテスト

[README](../README.md) · [QEMUでの使い方](usage.md)

GNU Make、内蔵LLD付きの [LDC 1.43.0](https://github.com/ldc-developers/ldc/releases/tag/v1.43.0)、EFI用の `lld-link` が必要です。実行には `qemu-system-x86_64` とx86-64用OVMF、アプリのインストールとテストには Python 3 も使います。`make` は `build/uefi-esp/` に `EFI/BOOT/BOOTX64.EFI` と `kernel.elf` を生成します。

`ldc2` をPATHに置くか、公式LDCを `build/tools/` に展開します。`lld-link` はPATHを探し、見つからなければインストール済みのRustに同梱されたものを探します。自動検出できない場合は `LDC`、`LLD_LINK`、`OVMF_CODE` で実際のパスを指定できます。

```sh
make run-gui LDC=/path/to/ldc2 OVMF_CODE=/path/to/OVMF_CODE.fd
make test
```

`make test` は使い捨てのディスクでQEMUを起動します。DlangFS3のディスクに6,145バイトのテキストを保存し、Editorで追記・保存します。再起動後には、編集済みの6,146バイトのテキストと16,384バイトのバイナリをバイト単位で照合します。DlangFS1/2のディスクを変更せずに拒否することも確認します。デスクトップ用 ELF のインストールとディスクからの起動、Dの共有コンストラクタの実行順、Ring 3でのヒープ割り当てと例外処理、Counterの入力と終了、破損した世代からの復旧、コードページ保護とプリエンプト、6つのGUIアプリの操作と `ps` への表示も確認します。

