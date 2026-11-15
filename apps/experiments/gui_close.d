/// 終了要求と未保存通知の競合を再現する。publish値でテストへ到達点を知らせる。
module gui_close;

import gui_abi : GuiEvent, GuiInput, GuiFrame;
import user_abi : Call, callError, userHeapBase, waitForever;
import user_api : call, send, exitApp;

extern(C) noreturn appMain() nothrow @nogc
{
    if (send(Call.guiCreate, "Close test") == callError) exitApp();
    auto frame = cast(GuiFrame*) userHeapBase;
    bool first = true;
    uint closes;
    while (true)
    {
        GuiInput input = void;
        if (call(Call.guiWait, cast(ulong) &input, first ? 0 : waitForever) == callError) exitApp();
        if (first)
        {
            call(Call.guiPresent, cast(ulong) frame);
            call(Call.publish, 1);
            first = false;
        }
        if (input.event == GuiEvent.close)
        {
            if (++closes == 1)
            {
                frame.dirty = 1;
                call(Call.guiPresent, cast(ulong) frame);
                call(Call.publish, 2);
                call(Call.sleep, 1500);
                call(Call.publish, 3); // 未保存通知の後なら終了猶予を越えて生存する。
            }
            else
            {
                call(Call.sleep, 1500);
                call(Call.publish, 5); // 保存済みのまま無応答なら、ここへ到達する前に回収される。
            }
        }
        if (input.event == GuiEvent.key && input.key == 10)
        {
            frame.dirty = 0;
            call(Call.guiPresent, cast(ulong) frame);
            call(Call.publish, 4);
        }
    }
}
