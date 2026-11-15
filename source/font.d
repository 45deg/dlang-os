/// IBM Plex Mono Mediumを元にしたASCII字形。2サイズそれぞれの画素濃度を組み込む。
module font;

enum int textWidth = 8;
enum int textHeight = 14;
enum int largeTextWidth = 16;
enum int largeTextHeight = 24;

private enum minCharacter = ' ';
private enum maxCharacter = '~';
private enum characterCount = maxCharacter - minCharacter + 1;
private immutable string smallAtlas = import("ui-8x14.coverage");
private immutable string largeAtlas = import("ui-16x24.coverage");

static assert(smallAtlas.length == characterCount * textWidth * textHeight);
static assert(largeAtlas.length == characterCount * largeTextWidth * largeTextHeight);

struct Glyph
{
    int width;
    int height;
    immutable(ubyte)[] coverage;
}

Glyph glyphFor(char character, int scale) pure nothrow @nogc
{
    if (character < minCharacter || character > maxCharacter)
        return Glyph.init;

    const large = scale == 2;
    const width = large ? largeTextWidth : textWidth;
    const height = large ? largeTextHeight : textHeight;
    const bytes = width * height;
    const start = (character - minCharacter) * bytes;
    const atlas = large ? largeAtlas : smallAtlas;
    return Glyph(width, height, cast(immutable(ubyte)[]) atlas[start .. start + bytes]);
}
