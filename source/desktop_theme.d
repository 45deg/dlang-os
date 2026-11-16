/// Draw the desktop wallpaper, app icons, and shared buttons.
module desktop_theme;

import font : textHeight, textWidth;
import graphics : Rect, Screen, minimum;

enum uint paper = 0xffffff;
enum uint ink = 0x152843;
enum uint muted = 0x405772;
enum uint divider = 0xc9d6e3;
enum uint accent = 0x135a56;
enum uint accentLight = 0xd9ece8;
enum uint warning = 0x8e381b;
enum uint toolbar = 0xe9eef4;
enum int taskbarHeight = 36;
enum int titleHeight = 25;

public import app_registry : App, apps;
import app_registry : registration, Icon;

nothrow @nogc:

const(char)[] appName(App app)
{
    return registration(app).title;
}

Rect shortcut(App app)
{
    const index = cast(int) app;
    return Rect(20 + index / 3 * 96, 22 + index % 3 * 77, 88, 66);
}

Rect appsButton(int height)
{
    return Rect(8, height - taskbarHeight + 6, 61, 24);
}

Rect menuBounds(int height)
{
    const menuHeight = cast(int) apps.length * 33 + 14;
    return Rect(8, height - taskbarHeight - menuHeight - 7, 191, menuHeight);
}

Rect menuItem(int height, App app)
{
    const bounds = menuBounds(height);
    return Rect(bounds.x + 8, bounds.y + 7 + cast(int) app * 33, bounds.width - 16, 29);
}

void drawWallpaper(ref Screen screen)
{
    const height = screen.height - taskbarHeight;
    // Layer slanted shapes from the right over a scanline gradient.
    foreach (y; 0 .. height)
    {
        const t = cast(uint) (y * 255 / height);
        screen.fill(Rect(0, y, screen.width, 1), mixColor(0x142941, 0x206365, t));
        const edge = screen.width * 7 / 8 - y / 2;
        screen.fill(Rect(edge, y, screen.width - edge, 1), mixColor(0x203953, 0x247773, t));
        const ridge = screen.width * 5 / 4 - y * 6 / 5;
        screen.fill(Rect(ridge, y, screen.width - ridge, 1), mixColor(0x263e58, 0x31877d, t));
    }
}

private uint mixColor(uint start, uint end, uint amount)
{
    uint result;
    foreach (shift; [0, 8, 16])
    {
        const a = (start >> shift) & 255;
        const b = (end >> shift) & 255;
        result |= ((a * (255 - amount) + b * amount) / 255) << shift;
    }
    return result;
}

void drawShortcut(ref Screen screen, App app)
{
    const rect = shortcut(app);
    screen.fill(Rect(rect.x, rect.y, rect.width, rect.height), 0x213d54);
    screen.fill(Rect(rect.x, rect.y + rect.height - 1, rect.width, 1), 0x4b697e);
    icon(screen, app, rect.x + 28, rect.y + 7);
    centeredText(screen, Rect(rect.x, rect.y + 46, rect.width, 16), appName(app), paper);
}

private void icon(ref Screen screen, App app, int x, int y)
{
    final switch (registration(app).icon)
    {
        case Icon.files:
            screen.fill(Rect(x + 2, y + 5, 14, 7), 0xefc57e);
            screen.fill(Rect(x + 1, y + 10, 31, 20), 0xefc57e);
            screen.fill(Rect(x + 3, y + 14, 29, 16), 0xffda97);
            break;
        case Icon.generic:
        case Icon.editor:
            screen.fill(Rect(x + 6, y + 1, 21, 30), 0xdde9f5);
            screen.fill(Rect(x + 22, y + 1, 5, 6), 0xa5bed8);
            foreach (row; 0 .. 3)
                screen.fill(Rect(x + 10, y + 11 + row * 5, row == 2 ? 9 : 13, 2), 0x617c9b);
            break;
        case Icon.counter:
            screen.fill(Rect(x + 1, y + 4, 31, 26), 0x31546a);
            screen.fill(Rect(x + 6, y + 19, 4, 7), 0x65d3ba);
            screen.fill(Rect(x + 14, y + 15, 4, 11), 0x65d3ba);
            screen.fill(Rect(x + 22, y + 10, 4, 16), 0x65d3ba);
            break;
        case Icon.calc:
            screen.fill(Rect(x + 5, y + 2, 23, 29), 0xbac8db);
            screen.fill(Rect(x + 9, y + 6, 15, 7), 0x26455a);
            foreach (row; 0 .. 2)
                foreach (column; 0 .. 3)
                    screen.fill(Rect(x + 9 + column * 6, y + 17 + row * 6, 3, 3), 0x415e77);
            break;
        case Icon.game:
            screen.fill(Rect(x + 1, y + 5, 31, 24), 0x28394a);
            screen.fill(Rect(x + 7, y + 16, 14, 4), 0x65d3ba);
            screen.fill(Rect(x + 17, y + 12, 4, 6), 0x65d3ba);
            screen.fill(Rect(x + 24, y + 12, 4, 4), 0xf1bc67);
            break;
        case Icon.monitor:
            screen.fill(Rect(x + 1, y + 4, 31, 23), 0xa9c1d7);
            screen.fill(Rect(x + 4, y + 7, 25, 17), 0x28394a);
            screen.fill(Rect(x + 7, y + 15, 7, 2), 0x71c5ed);
            screen.fill(Rect(x + 13, y + 11, 2, 7), 0x71c5ed);
            screen.fill(Rect(x + 15, y + 11, 11, 2), 0x71c5ed);
            screen.fill(Rect(x + 11, y + 29, 11, 2), 0xa9c1d7);
            break;
    }
}

void button(ref Screen screen, Rect rect, scope const(char)[] label, bool enabled = true)
{
    screen.fill(rect, enabled ? accent : divider);
    centeredText(screen, rect, label, enabled ? paper : muted);
}

void centeredText(ref Screen screen, Rect rect, scope const(char)[] label, uint color)
{
    if (rect.width < textWidth)
        return;
    const length = minimum(rect.width / textWidth, cast(int) label.length);
    screen.text(rect.x + (rect.width - length * textWidth) / 2,
        rect.y + (rect.height - textHeight) / 2, label[0 .. length], color);
}

void labelWithin(ref Screen screen, Rect rect, scope const(char)[] label, uint color)
{
    if (rect.width < textWidth)
        return;
    const length = minimum(rect.width / textWidth, cast(int) label.length);
    screen.text(rect.x, rect.y + (rect.height - textHeight) / 2, label[0 .. length], color);
}
