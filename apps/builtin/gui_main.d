/// デスクトップからイベントを受け取り、対象アプリの状態を更新して描画一覧を送る。
module gui_main;

import app_files : updateDisk;
import graphics : Rect, Screen;
import gui_abi : GuiEvent, GuiFrame, GuiInput;
import ps2 : Key;
import user_abi : Call, callError, userHeapBase;
import user_api : call, exitApp, send;

version (CalcApp)
{
    import calculator : Calculator;
    private __gshared Calculator app;
}
else version (GameApp)
{
    import snake : Snake;
    private __gshared Snake app;
}
else version (EditorApp)
{
    import editor : Editor, EditorClick;
    private __gshared Editor app;
}
else version (FilesApp)
{
    import file_browser : FileBrowser;
    private __gshared FileBrowser app;
}
else version (MonitorApp)
{
    import gui_abi : MonitorSnapshot;
    import monitor : drawMonitor, monitorRows;
}

extern(C) noreturn appMain() nothrow @nogc
{
    auto frame = cast(GuiFrame*) userHeapBase;
    bool first = true;
    bool focused;
    ulong diskGeneration;
    version (EditorApp) EditorClick drag;
    version (MonitorApp)
    {
        MonitorSnapshot stats;
        size_t firstRow;
        ulong lastRefresh;
    }

    while (true)
    {
        GuiInput input = void;
        if (call(Call.guiPoll, cast(ulong) &input) == callError)
            exitApp();
        updateDisk(input.mounted, input.diskGeneration);
        const diskChanged = diskGeneration != input.diskGeneration;
        const body = Rect(0, 0, input.width, input.height);
        const key = cast(Key) input.key;
        bool redraw = first || focused != input.focused || input.event != GuiEvent.none;

        version (EditorApp)
        {
            switch (input.event)
            {
                case GuiEvent.close:
                    if (!app.unsaved())
                        exitApp();
                    app.keepOpen();
                    break;
                case GuiEvent.key:
                    if (app.keyPress(key))
                        exitApp();
                    break;
                case GuiEvent.click:
                    drag = app.click(body, input.x, input.y);
                    if (drag == EditorClick.close)
                        exitApp();
                    break;
                case GuiEvent.drag, GuiEvent.release:
                    if (drag == EditorClick.select)
                        app.dragSelection(body, input.x, input.y);
                    else if (drag == EditorClick.scroll)
                        app.scrollPointer(body, input.y);
                    if (input.event == GuiEvent.release)
                        drag = EditorClick.none;
                    break;
                case GuiEvent.openDocument:
                    app.openDocument(input.filename[0 .. input.filenameLength]);
                    break;
                default: break;
            }
            redraw = redraw || diskChanged;
        }
        else
        {
            if (input.event == GuiEvent.close)
                exitApp();
        }

        version (CalcApp)
        {
            if (input.event == GuiEvent.key)
                app.keyPress(key);
            else if (input.event == GuiEvent.click)
                app.click(body, input.x, input.y);
        }
        else version (GameApp)
        {
            if (input.event == GuiEvent.key)
                app.keyPress(key, input.now);
            else if (input.event == GuiEvent.click)
                app.click(body, input.x, input.y, input.now);
            if (app.advance(input.now, input.focused))
                redraw = true;
        }
        else version (FilesApp)
        {
            if (first)
                app.refresh();
            else if (app.refreshIfChanged())
                redraw = true;

            const(char)[] name;
            if (input.event == GuiEvent.key)
                name = app.keyPress(key);
            else if (input.event == GuiEvent.click)
                name = app.click(body, input.x, input.y);
            if (name.length)
                send(Call.guiOpenDocument, name);
        }
        else version (MonitorApp)
        {
            if (first || input.now - lastRefresh >= 50)
            {
                call(Call.guiMonitor, cast(ulong) &stats);
                lastRefresh = input.now;
                redraw = true;
            }
            const rows = monitorRows(body);
            const lastRow = stats.running > rows ? stats.running - rows : 0;
            if (firstRow > lastRow)
                firstRow = lastRow;
            if (input.event == GuiEvent.key && key == Key.up && firstRow != 0)
                --firstRow;
            if (input.event == GuiEvent.key && key == Key.down && firstRow < lastRow)
                ++firstRow;
        }

        if (redraw)
        {
            frame.commandCount = frame.textCount = frame.titleLength = frame.dirty = 0;
            Screen screen = Screen(frame, body.width, body.height);
            version (EditorApp)
            {
                const title = app.title();
                foreach (i, char c; title)
                    frame.title[i] = c;
                frame.titleLength = cast(ubyte) title.length;
                frame.dirty = app.unsaved();
                app.draw(screen, body, input.focused);
            }
            else version (MonitorApp)
                drawMonitor(screen, body, stats, firstRow);
            else
                app.draw(screen, body);
            if (screen.overflow || call(Call.guiPresent, cast(ulong) frame) == callError)
                exitApp();
        }
        first = false;
        diskGeneration = input.diskGeneration;
        focused = input.focused;
    }
}
