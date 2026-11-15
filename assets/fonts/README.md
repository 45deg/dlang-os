# UI用の字形データ

Dlang OSの字形データは、IBM Plex Mono Mediumを元にしています。原著作権とSIL Open Font License 1.1は [OFL.txt](OFL.txt) を参照してください。

- [変換元のTTF（Google Fonts）](https://github.com/google/fonts/blob/633f3200539c52ee0aba2dfd7f46921417a81877/ofl/ibmplexmono/IBMPlexMono-Medium.ttf)
- TTFのSHA-256は `a9b4c49bb299e05b5f6c481e7fb5e78943d2793249a0c8874ab574a2d1ea6755` です。

`ui-8x14.coverage` と `ui-16x24.coverage` は、印字可能ASCII（0x20〜0x7e）を文字コード順に格納します。各文字は上から下、左から右の順で、1画素あたり1バイトの被覆率（0〜255）です。通常のビルドでは、同梱した二つの字形データをそのまま使います。

Pillowがある環境で、指定したTTFから作り直せます。

```sh
python3 tools/rasterize-font.py /path/to/IBMPlexMono-Medium.ttf assets/fonts
```
