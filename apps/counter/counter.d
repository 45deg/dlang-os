/// Counterは共通GUI APIで窓を作り、入力・描画を交換する。値は50 msごとに進める。
module counter;

import gui_abi : GuiEvent, GuiInput, GuiFrame, DrawCommand;
import user_abi : Call, callError, userHeapBase, waitForever;
import user_api : call, exitApp, send;

extern(C) noreturn appMain() nothrow @nogc
{
    if (send(Call.guiCreate, "Counter") == callError)
        exitApp();
    auto frame = cast(GuiFrame*) userHeapBase;
    ulong value, lastUpdate;
    bool paused, first = true;
    while (true)
    {
        GuiInput input = void;
        if (call(Call.guiWait, cast(ulong) &input, first ? 0 : paused ? waitForever : 50) == callError)
            exitApp();
        if (input.event == GuiEvent.close)
            exitApp();
        const toggle = input.event == GuiEvent.click
            || (input.event == GuiEvent.key && (input.key == 10 || input.key == 32));
        if (toggle)
            paused = !paused;
        bool changed = first || toggle;
        if (!paused && (first || input.now - lastUpdate >= 50))
        {
            ++value;
            lastUpdate = input.now;
            call(Call.publish, value);
            changed = true;
        }
        if (!changed)
            continue;
        frame.commandCount = frame.textCount = 0;
        frame.commands[frame.commandCount++] = DrawCommand(0, 0, cast(short) input.width,
            cast(short) input.height, 0xffffff, 0, 0);
        text(*frame, 13, 11, "User process", 0x607584, 1);
        char[20] digits;
        size_t start = digits.length;
        auto number = value;
        do { digits[--start] = cast(char) ('0' + number % 10); number /= 10; } while (number);
        text(*frame, 13, 34, paused ? "Paused" : digits[start .. $], 0x152843, 2);
        text(*frame, 13, 71, "Click or Enter sends input", 0x607584, 1);
        if (call(Call.guiPresent, cast(ulong) frame) == callError)
            exitApp();
        first = false;
    }
}

private void text(ref GuiFrame frame, short x, short y, scope const(char)[] value,
                  uint color, short scale) nothrow @nogc
{
    const offset = frame.textCount;
    foreach (c; value)
        frame.text[frame.textCount++] = c;
    frame.commands[frame.commandCount++] = DrawCommand(x, y, 0, scale, color,
        offset, cast(ushort) value.length);
}
