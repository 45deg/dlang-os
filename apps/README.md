# Dlang OSのユーザーアプリ

`make apps` で `build/apps/` に `hello.elf`、`counter.elf`、`d_init.elf`、`d_heap.elf`、`d_exception.elf`、`d_array.elf` と下記の Phobos サンプルをビルドします。`hello` と `counter` は `-betterC` を使い、入口は `extern(C) noreturn appMain() nothrow @nogc` です。

`hello.elf` を起動するには、ホストで `wc -c < build/apps/hello.elf` と `xxd -p -c 32 build/apps/hello.elf` を実行します。ゲストのシリアルシェルで `put hello.elf バイト数` を実行し、16進の本文と `.` だけの行を入力します。続いて `run hello.elf` を実行すると、シリアルにメッセージが出てアプリが終了します。

## `-betterC` なしで起動する

`d_init.elf` も同じ手順でディスクに置き、`run d_init.elf` で起動します。依存先とアプリ自身の `shared static this()` が順に実行され、D の `void main()` が `D shared static constructors ran before main.` と表示して終了します。

別の通常の D アプリを作るときは、Makefile の `D_APP_ELFS` にターゲットとアプリのソースを追加します。アプリ用ランタイムは LDC 1.43.0 の `x86_64-unknown-none-elf` に対応しています。`d_start` が `.init_array` を実行し、`ModuleInfo` をたどって依存先から共有コンストラクタを呼んだ後、D の `main` を呼びます。モジュール依存は循環のない構成を使います。

`d_heap.elf` は、スカラー、構造体、クラス、動的配列の `new` と `~=` を試すサンプルです。要素または同じ要素型のスライスを追加でき、必要に応じて以前の配列をコピーして拡張します。配列の要素はバイト単位でコピーできる型が対象です。`run d_heap.elf` は成功メッセージを出した後、意図的に割り当ての上限に達して終了します。

ヒープはプロセス終了時にまとめて再利用します。個別の解放、GC による回収、TLS、モジュールデストラクタ、Phobos 全体のリンクは未対応です。ヒープが足りない場合は `D application heap exhausted.` をシリアルに出し、そのプロセスを終了します。

`d_array.elf` は、動的配列のキャストと `~` による連結を試します。キャストは元の領域を共有し、バイト長に合わせて要素数を変えます。連結はバイト単位でコピーできる要素を対象に、結果用の領域を確保します。`run d_array.elf` は成功メッセージの後、要素数に端数が出るキャストを意図的に試し、プロセスのフォルトを確認できるようにしています。

## 例外処理

`Throwable` と派生クラスの `Exception`、`Error` を `throw` で送出できます。`catch` は型とその派生型を捕捉します。関数をまたぐ巻き戻しでは `finally` とスコープガードが実行されます。エラー時に `msg` を参照でき、未捕捉の例外はシリアルに出してアプリを終了します。`run d_exception.elf` では、型付きの捕捉、後始末、再スローを検証した後、意図的に未捕捉の例外を発生させます。

`Throwable.toString()` とデリゲートを取るオーバーロードは、例外を `型名@ファイル(行): メッセージ` の形で出力します。デリゲート版は渡された出力先に断片を送り、文字列をまとめて確保する必要がありません。`info` に渡した `TraceInfo` があれば、その内容も出力します。

通常の D アプリは LDC の `-exception-model=sjlj` でビルドします。`apps/runtime/d_unwind.d` が LLVM のフレームと ELF の `.gcc_except_table` を使って制御を移します。対応するのは明示的な D の `throw` です。例外の自動連鎖、スタックトレースの自動収集、他言語の例外との相互運用は未対応です。

## Phobos

`std.base64`、`std.digest.crc`、`std.digest.sha` は、LDC 同梱のソースを `x86_64-unknown-none-elf` 向けにモジュールごとにコンパイルし、必要なオブジェクトを各サンプルに静的リンクします。CRC と SHA の16進表示には `std.ascii` もリンクします。LDC のパッケージがソースを別の場所に置く場合は、`make apps PHOBOS_IMPORT=/path/to/import` で `std/` が入っているディレクトリを指定します。

ゲストで `run d_base64.elf`、`run d_crc.elf`、`run d_sha.elf` を実行すると、変換や計算の結果がシリアルに出ます。`make test` は Base64 のパディング3通り、CRC-32 の2入力、SHA-256 の短い入力と複数ブロックにわたる入力について、出力全体を照合します。

### 38 APIの対応状況

LDC 1.43.0 で各 API の代表的な使い方を試した結果です。QEMU を通過したのは14件で、今回の静的リンクで Base64、CRC-32、SHA-256 の3件が加わりました。

| 結果 | 件数 | API |
| --- | ---: | --- |
| QEMU で動作確認 | 14 | `std.traits.isIntegral`、`std.meta.AliasSeq`、`std.bitmanip.swapEndian`、`std.algorithm.searching.canFind`、`std.algorithm.sorting.sort`、`std.algorithm.iteration.map`、`std.range.iota`、`std.typecons.Tuple`、`std.exception.enforce`、`std.ascii.isAlpha`、`std.functional.unaryFun`、`std.base64.Base64.encode`、`std.digest.crc.crc32Of`、`std.digest.sha.sha256Of` |
| リンク失敗 | 3 | `std.utf.validate`、`std.random.Random`、`std.int128.Int128` |
| コンパイル失敗。対象環境の `core.stdc.time` が未対応 | 9 | `std.array.appender`、`std.format.format`、`std.datetime.systime.Clock.currTime`、`std.process.environment`、`std.parallelism.totalCPUs`、`std.concurrency.thisTid`、`std.container.array.Array`、`std.uri.encode`、`std.datetime.date.Date` |
| コンパイル失敗。対象環境で `c_long` を解決できない | 5 | `std.numeric.gcd`、`std.string.strip`、`std.conv.to`、`std.math.abs`、`std.regex.regex` |
| コンパイル失敗。C ABI の型や対象環境の分岐が未対応 | 6 | `std.stdio.writeln`、`std.checkedint.Checked`、`std.socket.Socket`、`std.file.exists`、`std.path.baseName`、`std.experimental.allocator.mallocator.Mallocator` |
| コンパイル失敗。連想配列の `TypeInfo` がない | 1 | `std.json.parseJSON` |

## ローダーとABI

ロードできるのは、静的にリンクしたx86-64・リトルエンディアンのELF64 `ET_EXEC` です。1実行ファイルはDlangFSの上限16 KiBまでです。`PT_LOAD` は `0x00400000` から `0x00408000` 未満の範囲に、4 KiB境界で重ならないよう配置します。同じセグメントに書き込みと実行の両方の権限は指定できません。実行権限のあるファイル範囲に入口を置きます。動的リンク、再配置、TLS、引数の受け渡しは未実装です。

各プロセスは別のページテーブルと16 KiBのファイル上限とは独立した32 KiBのロード領域を持ちます。1ページのスタックは `0x00410000` から `0x00411000` 未満にあります。ELFプロセスは `0x00412000` から `0x00422000` 未満にプロセス専用の64 KiBのヒープを持ちます。スタックとヒープは書き込み可能で、実行は禁止です。起動時に `.bss` とヒープをゼロで初期化します。

`INT 0x80` の入力は RAX に番号、RDI と RSI に引数を入れます。戻り値は RAX で、エラーは `ulong.max` です。文字列を受け取る呼び出しでは RDI がポインタ、RSI がバイト数です。カーネルはマップ済みのユーザーページからだけ文字列をコピーします。

| 番号 | 名前 | 動作 |
| --- | --- | --- |
| 0 | `yield` | 実行をいったん譲る |
| 1 | `publish` | RDIの値をプロセス統計に公開する |
| 2 | `exit` | プロセスを終了する |
| 3 | `write` | ASCIIとLFをシリアルへ出す。1回最大128バイト |
| 4 | `windowOpen` | 1プロセスにつき1枚のウィンドウを要求する。タイトルはASCIIで1〜24バイト |
| 5 | `windowText` | ウィンドウの本文を短いASCII文字列で更新する。最大28バイト |
| 6 | `windowEvent` | 入力なし（0）、本文クリックまたはEnter/Space（1）、閉じる通知（2）を返す |

Counterは入力イベントで一時停止と再開を切り替え、閉じる通知を受けると自分で終了します。ウィンドウ枠と文字描画はカーネルが担当します。
