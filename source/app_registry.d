/// Desktop app registry and built-in defaults used when there is no configuration file.
/// external provides defaults for apps that call guiCreate from the shell or another path outside the launcher.
module app_registry;

import graphics : Rect;
import ps2 : Key;

alias App = size_t;
enum appLimit = 12;
enum App externalApp = appLimit;
enum Icon { files, editor, counter, calc, game, monitor, generic }

struct AppRegistration
{
    const(char)[] title, executable;
    Rect bounds;
    int cascadeX, cascadeY;
    bool fromRight;
    uint instances; // 0 uses the overall window limit. 1 brings the existing window to the front.
    Key launchKey;
    const(char)[] keyLabel;
    bool documents;
    Icon icon = Icon.generic;
}

private immutable AppRegistration[] defaults = [
    AppRegistration("Files", "files.elf", Rect(128, 49, 294, 354), 0, 0, false, 1, Key.openFiles, "F5", false, Icon.files),
    AppRegistration("Editor", "editor.elf", Rect(199, 76, 468, 340), 24, 29, false, 4, Key.newEditor, "F8", true, Icon.editor),
    AppRegistration("Counter", "counter.elf", Rect(-292, 113, 256, 123), -33, 81, true, 0, Key.newCounter, "F9", false, Icon.counter),
    AppRegistration("Calc", "calc.elf", Rect(185, 64, 282, 312), 18, 20, false, 0, Key.none, "", false, Icon.calc),
    AppRegistration("Game", "game.elf", Rect(207, 94, 334, 303), 22, 25, false, 1, Key.none, "", false, Icon.game),
    AppRegistration("Monitor", "monitor.elf", Rect(-448, 55, 420, 319), -14, 17, true, 1, Key.none, "", false, Icon.monitor),
];
private immutable external = AppRegistration("Application", "", Rect(-292, 113, 256, 123), -33, 81, true);
private __gshared AppRegistration[appLimit] registrations;
private __gshared App[appLimit] identifiers;
private __gshared size_t count;

nothrow @nogc:

const(App)[] apps() { return identifiers[0 .. count]; }

/// The caller keeps strings alive. Apply the entire configuration at boot.
void setRegistrations(scope const(AppRegistration)[] entries)
{
    assert(entries.length > 0 && entries.length <= appLimit);
    count = entries.length;
    foreach (i; 0 .. count)
    {
        registrations[i] = entries[i];
        identifiers[i] = i;
    }
}

void defaultRegistrations() { setRegistrations(defaults); }

ref const(AppRegistration) registration(App app)
{
    return app < count ? registrations[app] : external;
}

App documentApp()
{
    foreach (app; apps)
        if (registration(app).documents)
            return app;
    return externalApp;
}
