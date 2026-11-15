/// 矩形とASCII文字をRAMに合成し、presentで指定範囲をUEFIから引き継いだフレームバッファへ転送する。
module graphics;

import font : glyphFor, largeTextWidth, textWidth;
import ldc.llvmasm : __asm;
import boot_info : bootFramebuffer, bootBackBuffer;

struct Rect
{
    int x;
    int y;
    int width;
    int height;

    bool contains(int px, int py) const nothrow @nogc
    {
        return px >= x && px < x + width && py >= y && py < y + height;
    }

    Rect covering(Rect other) const nothrow @nogc
    {
        if (width <= 0 || height <= 0)
            return other;
        if (other.width <= 0 || other.height <= 0)
            return this;
        const left = minimum(x, other.x);
        const top = minimum(y, other.y);
        return Rect(left, top, maximum(x + width, other.x + other.width) - left,
            maximum(y + height, other.y + other.height) - top);
    }
}

version (GuiApp)
{
    import gui_abi : DrawCommand, GuiFrame;

    struct Screen
    {
        GuiFrame* frame;
        int width, height;
        bool overflow;

        nothrow @nogc:

        void fill(Rect rect, uint rgb)
        {
            if (rect.width <= 0 || rect.height <= 0)
                return;
            append(rect, rgb, null);
        }

        void text(int x, int y, scope const(char)[] label, uint rgb, int scale = 1)
        {
            if (label.length)
                append(Rect(x, y, 0, scale), rgb, label);
        }

        void character(int x, int y, char c, uint rgb, int scale = 1)
        {
            if (c >= ' ' && c <= '~')
                text(x, y, (&c)[0 .. 1], rgb, scale);
        }

        private void append(Rect rect, uint rgb, scope const(char)[] label)
        {
            if (frame.commandCount == frame.commands.length
                || label.length > frame.text.length - frame.textCount)
            {
                overflow = true;
                return;
            }
            frame.commands[frame.commandCount++] = DrawCommand(cast(short) rect.x, cast(short) rect.y,
                cast(short) rect.width, cast(short) rect.height, rgb, frame.textCount, cast(ushort) label.length);
            foreach (char c; label)
                frame.text[frame.textCount++] = c;
        }
    }
}
else
struct Screen
{
    int width;
    int height;

    private Rect clip;
    private uint* framebuffer;
    private size_t framebufferStride;
    private uint* backBuffer;
    private ubyte redShift;
    private ubyte greenShift;
    private ubyte blueShift;

    nothrow @nogc:

    bool init()
    {
        auto frame = bootFramebuffer();
        if (frame.address is null)
            return false;
        backBuffer = bootBackBuffer();
        framebuffer = frame.address;
        width = cast(int) frame.width;
        height = cast(int) frame.height;
        clip = Rect(0, 0, width, height);
        framebufferStride = frame.pitchBytes / uint.sizeof;
        redShift = frame.redShift;
        greenShift = frame.greenShift;
        blueShift = frame.blueShift;
        return true;
    }

    void clipTo(Rect rect)
    {
        const left = maximum(0, rect.x);
        const top = maximum(0, rect.y);
        const right = minimum(width, rect.x + rect.width);
        const bottom = minimum(height, rect.y + rect.height);
        clip = Rect(left, top, maximum(0, right - left), maximum(0, bottom - top));
    }

    void resetClip()
    {
        clip = Rect(0, 0, width, height);
    }

    uint encode(uint rgb) const
    {
        return (((rgb >> 16) & 255) << redShift) | (((rgb >> 8) & 255) << greenShift)
            | ((rgb & 255) << blueShift);
    }

    uint pixel(int x, int y) const
    {
        return backBuffer[y * width + x];
    }

    void putPixel(int x, int y, uint nativeColor)
    {
        backBuffer[y * width + x] = nativeColor;
    }

    void fill(Rect rect, uint rgb)
    {
        const right = minimum(clip.x + clip.width, rect.x + rect.width);
        const bottom = minimum(clip.y + clip.height, rect.y + rect.height);
        const left = maximum(clip.x, rect.x);
        const color = encode(rgb);
        for (int y = maximum(clip.y, rect.y); y < bottom; ++y)
        {
            auto row = backBuffer + y * width;
            for (int x = left; x < right; ++x)
                row[x] = color;
        }
    }

    /// 描き終えた画素だけを、画面側のピッチに合わせて行単位で転送する。
    void present(Rect damage)
    {
        const left = maximum(0, damage.x);
        const right = minimum(width, damage.x + damage.width);
        const bottom = minimum(height, damage.y + damage.height);
        if (right <= left)
            return;
        const pixels = cast(size_t) (right - left);
        for (int y = maximum(0, damage.y); y < bottom; ++y)
        {
            auto destination = framebuffer + y * framebufferStride + left;
            const source = backBuffer + y * width + left;
            __asm("rep movsl", "{rdi},{rsi},{rcx},~{rdi},~{rsi},~{rcx},~{memory}",
                destination, source, pixels);
        }
        __asm("sfence", "~{memory}");
    }

    void text(int x, int y, scope const(char)[] label, uint rgb, int scale = 1)
    {
        const step = scale == 2 ? largeTextWidth : textWidth;
        foreach (char c; label)
        {
            character(x, y, c, rgb, scale);
            x += step;
        }
    }

    void character(int x, int y, char c, uint rgb, int scale = 1)
    {
        const glyph = glyphFor(c, scale);
        const left = maximum(0, clip.x - x);
        const right = minimum(glyph.width, clip.x + clip.width - x);
        const top = maximum(0, clip.y - y);
        const bottom = minimum(glyph.height, clip.y + clip.height - y);
        if (right <= left || bottom <= top)
            return;
        const ink = encode(rgb);
        for (int row = top; row < bottom; ++row)
        {
            auto target = backBuffer + (y + row) * width + x + left;
            for (int col = left; col < right; ++col, ++target)
            {
                const alpha = glyph.coverage[row * glyph.width + col];
                if (alpha != 0)
                    *target = alpha == 255 ? ink : blend(ink, *target, alpha);
            }
        }
    }

    private uint blend(uint over, uint under, uint alpha) const
    {
        return blendChannel(over, under, alpha, redShift)
            | blendChannel(over, under, alpha, greenShift)
            | blendChannel(over, under, alpha, blueShift);
    }
}

private uint blendChannel(uint over, uint under, uint alpha, ubyte shift) pure nothrow @nogc
{
    const foreground = (over >> shift) & 255;
    const background = (under >> shift) & 255;
    return ((foreground * alpha + background * (255 - alpha) + 127) / 255) << shift;
}

int minimum(int a, int b) pure nothrow @nogc { return a < b ? a : b; }
int maximum(int a, int b) pure nothrow @nogc { return a > b ? a : b; }
