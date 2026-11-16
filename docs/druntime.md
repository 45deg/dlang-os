# 標準druntimeの移植基盤

対象はLDC 1.43.0、`x86_64-unknown-none-elf`、静的リンク、1プロセス1スレッドです。現在は**LP64のC ABI、主スレッドのTLS、標準druntimeのモジュール初期化と通常終了処理**に対応しています。標準druntime全体の移植はまだ完了していません。既存の `apps/runtime/` は従来のアプリで引き続き使用します。上流 `std.stdio.writeln` の追加移植は [Phobosの手順](phobos.md) を参照してください。

## 取得とビルド

```sh
make druntime-fetch
make druntime-bootstrap
make druntime-startup
make test-druntime
make druntime-package
```

取得時だけネットワークを使います。通常の `make` / `make test` はダウンロードしません。取得済みアーカイブを使う場合は次のように指定できます。同じSHA-256検査を行います。

```sh
make druntime-fetch DRUNTIME_ARCHIVE=/path/to/ldc-v1.43.0.tar.gz
```

`runtime/druntime/source.lock.json` に公式アーカイブのURL、SHA-256、LDCコミット、druntimeのツリーIDを固定しています。取得物は `build/druntime/` に置き、標準druntimeのソースを変更せずに展開します。ビルド時はファイル一覧と各ファイルのハッシュを検証します。バージョン変更時は別途ソースとライセンスをレビューし、既存のキャッシュを残したまま新しいビルド用ディレクトリを用意してください。

LDCの空の設定ファイルと固定ソースへの明示的なimportパスを使用し、ホストのライブラリやimport設定を取り込みません。`-betterC` は使用せず、対象triple、静的再配置、red zone無効化を明示します。ランタイム側の部分ビルドでは `-fno-moduleinfo` を使います。起動確認用アプリはモジュール情報を生成し、登録と初期化を実行します。`DlangOS` のversion識別子を渡しますが、LinuxやPOSIXとして扱う設定は追加していません。

## 成果物と検証範囲

`build/druntime/bootstrap/` に以下を生成します。

- `libdruntime-bootstrap.a`：`core.bitop`、`rt.aApply`、`rt.aApplyR` の部分アーカイブ。各オブジェクトのELF64・x86-64・再配置可能形式を検査します。
- `druntime_bootstrap.elf`：標準 `object.d` をimportし、アーカイブ内の `core.bitop.bsf` を関数ポインタ経由で呼ぶ検証アプリ。96 KiBの初期化済みデータも全バイト照合します。
- `link.map`：どのアーカイブメンバーとシンボルがリンクされたか確認するためのマップ。
- `report.json`：ソースの固定情報、コンパイルコマンド、成否と診断。
- ライセンス本文、NOTICE、ソースの固定情報。

`test-druntime` は使い捨てDlangFS4ディスクへELFを転送し、再起動後に全バイトの一致とRing 3での実行結果を確認します。新しい1 MiB上限に対し、従来の16bit長を超える実行ファイルをロードできることも検証します。

`rt.aApply` / `rt.aApplyR` はコンパイルまでの検証です。UTF変換や `onUnicodeError` への未解決参照が残るため、これらを使うプログラムを現時点で一般にリンクできるとは限りません。実行確認済みなのは `core.bitop` の呼び出しです。この部分アーカイブとは別に、次節の起動用アーカイブを用意しています。

## 主スレッドのTLSと標準起動処理

`make druntime-startup` は `build/druntime/startup/libdruntime-startup.a` と2種類の検証ELFを作ります。Cとの相互呼び出しの確認にClangを使います。`DRUNTIME_CC=/path/to/clang` で指定できます。C側もx86-64のfreestanding設定でコンパイルし、ホストのヘッダ・libcは使いません。

上流ソースは `runtime/druntime/patches/0001-dlangos-startup.patch` を別コピーへ適用します。元のソースとライセンス表示は保持します。追加のOS依存実装は `runtime/druntime/port/dlangos/` にあります。

- C ABI：64bitの `c_long` / `c_ulong`、ポインタ、`intptr_t` / `uintptr_t`、32bitの `wchar_t` などを定義。初期化処理に必要な `malloc` / `calloc` / `realloc` / `free`、文字列処理、TLSの `errno`、シリアル出力を実装します。Cヒープは解放領域を再利用しますが、GCではありません。
- Cの入出力はシリアルへの同期出力に限定します。`fprintf` は `%s`、`%.*s`、`%d`、`%u`、`%%` に対応し、未対応書式はエラーを返します。宣言だけあるC APIもあり、C標準ライブラリ全体への対応ではありません。浮動小数点・SIMDのコンテキスト保存も未対応です。
- TLS：静的なx86-64 local-exec方式です。ELFの `PT_TLS` から `.tdata` をコピーし、`.tbss` をゼロ化します。1プロセス1主スレッドとし、スケジューラがFSベースを設定します。TLSは最大64 KiB、アラインメントは最大4 KiBです。イメージ領域末尾の128 KiBをTLS用に予約します。
- 起動：入口で `.init_array` の登録関数を実行し、上流 `_d_run_main` → `rt_init` → `rt.sections_ldc` / `rt.minfo` のモジュール依存順序計算・共有コンストラクタ・TLSコンストラクタを通ってDの `main` に入ります。引数は空配列です。
- 通常終了：TLSデストラクタ、共有デストラクタをそれぞれ逆依存順に実行し、登録用の領域を解放します。強制終了・CPUフォルトではデストラクタを実行しません。

`rt.dmain2` のDlangOS分岐は、まだ移植していないGC、モニター、OSスレッド、unittestランナー、例外トラップを呼びません。コンストラクタの循環依存や初期化用メモリ不足は診断してプロセスを終了します。`new`、連想配列、標準GC、一般的な例外処理、追加スレッドは今回の対応範囲外です。既存のSjLj補助コードをリンクしますが、標準druntime全体の例外サポートを保証するものではありません。

QEMUではCでコンパイルした関数への64bit整数・ポインタ・構造体の受け渡し、CからDへのコールバック、Cヒープの内容保持、依存する2モジュールの初期化と終了順序を確認します。異なるTLS値を持つ2プロセスを同時に起動し、実際のタイマーによるプリエンプトを経ても値と `errno` が維持されること、再起動時のTLS初期化、不正なTLSヘッダの拒否とページ回収も検証します。

## 未対応箇所の診断

```sh
make druntime-audit
```

`object.d`、起動処理、割り当て、GC、OSスレッド、セクション登録の6モジュールを個別にクロスコンパイルし、`build/druntime/audit/report.json` と各ログへ結果を保存します。失敗があればコマンドも非ゼロで終了します。全ソースのビルドやリンク検証を代用するものではありません。

この診断はパッチ未適用の上流ソースを対象とするため、`core.stdc.time` の対象OS未対応やC ABI型の未定義で失敗します。パッチ適用後の起動経路は `make druntime-startup` / `make test-druntime` で検証します。残るGC・例外・スレッドなどを進める際には診断対象も拡充します。

## ライセンスと再配布用の記録

[NOTICE](../runtime/druntime/NOTICE.md)、[Boostライセンス全文](../runtime/druntime/LICENSE-Boost.txt)、[LDCのライセンス一覧と全文](../runtime/druntime/LICENSE-LDC.txt)をリポジトリに保持します。各ソースの著作権・著者・ライセンス表示も元のまま保持しています。コンパイラ本体とランタイムのライセンスを混同せず、プロジェクト全体のライセンスを変更するものでもありません。

`make druntime-package` は `build/druntime/druntime-bootstrap-bundle.tar.gz` を生成します。部分アーカイブと起動用アーカイブ、検証ELF、ビルド情報、ライセンス、NOTICE、元ソースのアーカイブ、移植パッチ、OS依存ソース、リンカスクリプトをまとめます。元ソースのアーカイブにはLDCの他のコンポーネントも含まれるので、その元のライセンス表示も保持します。

今後ソースを修正する場合は元の表示を残し、変更をレビュー可能なパッチとして管理します。Cライブラリやアンワインダなどの依存を追加するときは、取得元・版・ライセンス・配布物に含める表示を追加してからリンク対象にします。
