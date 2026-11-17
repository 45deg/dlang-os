# Hello, world 実装

上流の `std.stdio.writeln` を使い、次のプログラムをQEMUのシリアルへ出力できます。

```d
import std.stdio : writeln;

void main()
{
    writeln("Hello, world!");
}
```

実際のソースは [phobos_hello.d](../apps/experiments/phobos_hello.d) にあります。独自の `writeln` に置き換えているわけではなく、上流の `writeln` → `File.LockingTextWriter` → C入出力アダプター → システムコールという経路を通ります。

## ビルドと実行確認

標準druntimeの取得を済ませたLDC 1.43.0環境で実行します。前提条件は [druntimeの手順](druntime.md) と同じです。

```sh
make druntime-fetch
make phobos-fetch
make test-phobos
```

ネットワークを使うのは取得ターゲットだけです。取得済みのアーカイブを渡す場合は `make phobos-fetch PHOBOS_ARCHIVE=/path/to/phobos-source.tar.gz` と指定します。ビルドだけを行いたい場合は `make phobos-output` を使えます。

生成物は `build/phobos/output/` にあります。

- `phobos_hello.elf`：上記のHello, worldプログラム。
- `phobos_output.elf`：連続出力、UTF-8、動的配列からの長い出力に加え、実際のI/Oエラー発生時と閉じた `File` への出力を確認するアプリ。
- `libphobos-output.a`：必要なPhobos・druntimeモジュールの部分アーカイブ。
- 各ELFのリンクマップ、ビルドコマンドとソースのバージョンを記録した `report.json`、ライセンスとNOTICE。

`test-phobos` は使い捨てのDlangFSディスクにELFを保存し、再起動して通常のローダーから実行します。出力をバイト単位で照合するほか、例外を捕捉した後の終了、再実行時のストリーム初期化、終了後のページ回収も確認します。Hello, worldの出力は `Hello, world!` と改行です。

## 移植範囲

静的リンク、1プロセス1スレッドの構成です。`std.stdio`、`std.utf`、`std.exception` と必要なテンプレートを上流ソースからコンパイルしており、`writeln` と `File.LockingTextWriter` の本体は変更していません。標準ストリームはプロセス内だけで使うため、Cストリームのロック処理は不要です。

C側ではストリームの向き、文字出力、クローズ、エラーを扱います。シリアルAPIは印字可能ASCII、LF、および `0x80` 以上のバイトを受け付け、UTF-8の途中で128バイトの転送境界に達してもそのまま送信します。UTF-8の検証はカーネル側では行いません。LFはCRLFへ変換し、LF以外のASCII制御文字は拒否します。この拒否を利用し、Phobosが `ErrnoException` を投げる経路もQEMUで確認しています。GUIのタイトルとフォントは引き続きASCIIです。

文字列や例外を扱うため、上流のクラス割り当て、配列処理、整数と文字の型情報を追加しています。`dlangos.gc` は割り当てた領域と配列の使用長を追跡しますが、**走査型GCではありません**。D側の割り当てはプロセス終了まで保持され、カーネルがまとめて回収するため、長時間の実行ではヒープ上限に達します。Cの `malloc` / `free` は従来どおり解放領域を再利用します。

標準の例外型と既存のSjLjアンワインダーを使い、この出力経路における例外捕捉を確認しています。一般的なPhobos全体、ファイルの読み書き、標準入力、スレッドとモニター、浮動小数点とSIMD、標準GCは未対応です。未実装のC APIはリンクエラーになり、ファイル同期やファイルロックなどのOS依存分岐は未対応として例外を投げます。成功を装う代替処理は入れていません。

## ソースとライセンス

LDC v1.43.0が指定するPhobosのコミット `4d4842eff1f50b9edd90b9a7fc470a7b2fc4e85c` を使用し、[source.lock.json](../runtime/phobos/source.lock.json) に取得元とSHA-256を固定しています。元のソース全体を保持したまま、別のコピーへ [移植パッチ](../runtime/phobos/patches/) を適用します。

上流の著作権表示とライセンス表示を残し、[Boostライセンス本文](../runtime/phobos/LICENSE_1_0.txt) と [NOTICE](../runtime/phobos/NOTICE.md) を同梱しています。`make phobos-package` は元ソース、移植パッチ、OSアダプター、ビルド情報、およびdruntimeの配布用バンドルを `build/phobos/phobos-output-bundle.tar.gz` にまとめます。
