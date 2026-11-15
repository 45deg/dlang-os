/// 独立したCounterアプリ。値を計算して表示用テキストを送り、入力イベントを待つ。
module counter;

import user_abi : Call, WindowEvent, callError;
import user_api : call, exitApp, send;

extern(C) noreturn appMain() nothrow @nogc
{
    if (send(Call.windowOpen, "Counter") == callError)
        exitApp();

    ulong value;
    bool paused;
    while (true)
    {
        const event = call(Call.windowEvent);
        if (event == WindowEvent.close)
            exitApp();
        if (event == WindowEvent.activate)
        {
            paused = !paused;
            if (paused)
                send(Call.windowText, "Paused");
        }
        if (paused)
            continue;

        ++value;
        char[20] buffer = void;
        size_t start = buffer.length;
        ulong digits = value;
        do
        {
            buffer[--start] = cast(char) ('0' + digits % 10);
            digits /= 10;
        }
        while (digits != 0);
        send(Call.windowText, buffer[start .. $]);
        call(Call.publish, value);
    }
}
