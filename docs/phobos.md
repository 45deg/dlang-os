# 上流Phobosのwriteln

上流の `std.stdio.writeln` で、次のプログラムをQEMUのシリアルへ出力できます。

```d
import std.stdio : writeln;

void main()
{
    writeln("Hello, world!");
}
```

実際のソースは [phobos_hello.d](../apps/experiments/phobos_hello.d) です。独自の `writeln` への置き換えではありません。上流の `writeln` → `File.LockingTextWriter` → C入出力アダプター → システムコールを通ります。

## ビルドと実行確認

標準druntimeの取得を済ませたLDC 1.43.0環境で実行します。前提は [druntimeの手順](druntime.md) と同じです。

```sh
make druntime-fetch
make phobos-fetch
make test-phobos
```

ネットワークを使うのは取得ターゲットだけです。取得済みのアーカイブを渡す場合は `make phobos-fetch PHOBOS_ARCHIVE=/path/to/phobos-source.tar.gz` とします。`make phobos-output` でビルドだけを行えます。

生成物は `build/phobos/output/` にあります。

- `phobos_hello.elf`：上記のHello world。
- `phobos_output.elf`：連続出力、UTF-8、動的配列からの長い出力、実際のI/Oエラーと閉じたFileへの出力を確認するアプリ。
- `libphobos-output.a`：必要なPhobos・druntimeモジュールの部分アーカイブ。
- 各ELFのリンクマップ、ビルドコマンドとソースの版を記録する `report.json`、ライセンスとNOTICE。

`test-phobos` は使い捨てDlangFS4にELFを保存し、再起動して通常のローダーから実行します。出力をバイト単位で照合し、例外を捕捉した後の終了、再実行時のストリーム初期化、終了後のページ回収も確認します。Hello worldの出力は `Hello, world!` と改行です。

## 移植範囲

静的リンク、1プロセス1スレッドです。`std.stdio`、`std.utf`、`std.exception` と必要なテンプレートを上流ソースからコンパイルします。`writeln` と `File.LockingTextWriter` の本体は変更していません。標準ストリームはプロセス内だけで使うため、Cストリームのロックは処理不要です。

C側ではストリームの向き、文字出力、クローズ、エラーを扱います。シリアルAPIは印字可能ASCII・LFと0x80以上のバイトを受け付け、UTF-8の途中で128バイトの転送境界に達してもそのまま送ります。UTF-8の検証はカーネルで行いません。LFはCRLFへ変換し、LF以外のASCII制御文字は拒否します。この拒否を使って、Phobosが `ErrnoException` を投げる経路もQEMUで確認しています。GUIのタイトル・フォントは引き続きASCIIです。

文字列や例外のために、上流のクラス割り当て・配列処理・整数と文字の型情報を追加しています。`dlangos.gc` は割り当てた領域と配列の使用長を追跡しますが、**走査型GCではありません**。D側の割り当てはプロセス終了まで保持し、カーネルがまとめて回収します。長時間の実行ではヒープ上限に達します。Cの `malloc` / `free` は従来どおり解放領域を再利用します。

標準の例外型と既存のSjLjアンワインダーで、この出力経路の例外捕捉を確認しています。一般的なPhobos全体、ファイルの読み書き、標準入力、スレッド・モニター、浮動小数点・SIMD、標準GCは未対応です。未実装のC APIはリンクエラーになり、ファイル同期・ファイルロックなどのOS依存分岐は未対応として例外を投げます。成功を装う代替処理は入れていません。

## ソースとライセンス

LDC v1.43.0が指定するPhobosのコミット `4d4842eff1f50b9edd90b9a7fc470a7b2fc4e85c` を使用します。[source.lock.json](../runtime/phobos/source.lock.json) に取得元とSHA-256を固定しています。元のソース全体を保持し、別コピーに [移植パッチ](../runtime/phobos/patches/) を適用します。

上流の著作権表示・ライセンス表示を残し、[Boostライセンス本文](../runtime/phobos/LICENSE_1_0.txt) と [NOTICE](../runtime/phobos/NOTICE.md) を同梱します。`make phobos-package` は元ソース、移植パッチ、OSアダプター、ビルド情報とdruntimeの配布用バンドルを `build/phobos/phobos-output-bundle.tar.gz` にまとめます。
