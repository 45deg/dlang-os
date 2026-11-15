/// 同梱デスクトップの登録情報。起動先・窓配置・多重起動・文書担当をここで定義する。
/// externalはシェルなどからguiCreateした、ランチャーに登録されていないアプリの既定値。
module app_registry;

import graphics : Rect;
import ps2 : Key;

enum App { files, editor, counter, calc, game, monitor, external }
immutable App[] apps = [App.files, App.editor, App.counter, App.calc, App.game, App.monitor];

struct AppRegistration
{
    string title, executable;
    Rect bounds;
    int cascadeX, cascadeY;
    bool fromRight;
    uint instances; // 0はウィンドウ全体の上限まで。1は既存の窓を前面へ戻す。
    Key launchKey;
    string keyLabel;
    bool documents;
}

private immutable AppRegistration[] registrations = [
    AppRegistration("Files", "files.elf", Rect(128, 49, 294, 354), 0, 0, false, 1, Key.openFiles, "F5"),
    AppRegistration("Editor", "editor.elf", Rect(199, 76, 468, 340), 24, 29, false, 4, Key.newEditor, "F8", true),
    AppRegistration("Counter", "counter.elf", Rect(-292, 113, 256, 123), -33, 81, true, 0, Key.newCounter, "F9"),
    AppRegistration("Calc", "calc.elf", Rect(185, 64, 282, 312), 18, 20),
    AppRegistration("Game", "game.elf", Rect(207, 94, 334, 303), 22, 25, false, 1),
    AppRegistration("Monitor", "monitor.elf", Rect(-448, 55, 420, 319), -14, 17, true, 1),
    AppRegistration("Application", "", Rect(-292, 113, 256, 123), -33, 81, true),
];
static assert(registrations.length == App.max + 1);

ref const(AppRegistration) registration(App app) nothrow @nogc
{
    return registrations[cast(size_t) app];
}

App documentApp() nothrow @nogc
{
    foreach (app; apps)
        if (registration(app).documents)
            return app;
    return App.external;
}
