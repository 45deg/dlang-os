/// Validate desktop.apps and replace the entire registry at boot. Keep its strings in a dedicated buffer.
module app_catalog;

import app_registry : AppRegistration, Icon, appLimit, defaultRegistrations, setRegistrations;
import filesystem : open, FsResult, FileVersion;
import file_api : validFilename;
import graphics : Rect;
import gui_abi : maxGuiWindows;
import ps2 : Key;

private __gshared char[4096] snapshot;
private immutable string[7] icons = ["files", "editor", "counter", "calc", "game", "monitor", "generic"];
static assert(icons.length == Icon.max + 1);

nothrow @nogc:

const(char)[] loadCatalog()
{
    defaultRegistrations();
    const(char)[] content;
    FileVersion stored;
    const result = open("desktop.apps", content, stored);
    if (result == FsResult.notFound || result == FsResult.unavailable) return null;
    if (result != FsResult.ok || content.length > snapshot.length)
        return "Cannot read desktop.apps; using default apps.";
    foreach (i, c; content) snapshot[i] = c;
    AppRegistration[appLimit] entries;
    size_t count;
    if (!parse(snapshot[0 .. content.length], entries, count))
        return "Invalid desktop.apps; using default apps.";
    setRegistrations(entries[0 .. count]);
    return null;
}

private bool parse(const(char)[] text, ref AppRegistration[appLimit] entries, out size_t count)
{
    bool header, document;
    while (text.length)
    {
        size_t end;
        while (end < text.length && text[end] != '\n') ++end;
        auto line = text[0 .. end];
        text = end < text.length ? text[end + 1 .. $] : null;
        if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
        if (!line.length || line[0] == '#') continue;
        if (!header)
        {
            if (line != "DLANGAPPS1") return false;
            header = true;
            continue;
        }
        if (count == entries.length) return false;
        const(char)[][10] fields;
        size_t start, index;
        foreach (i; 0 .. line.length + 1)
            if (i == line.length || line[i] == '|')
            {
                if (index == fields.length) return false;
                fields[index++] = line[start .. i];
                start = i + 1;
            }
        if (index != fields.length) return false;
        auto entry = &entries[count];
        entry.title = fields[0];
        entry.executable = fields[1];
        if (entry.title.length == 0 || entry.title.length > 24 || !validFilename(entry.executable)) return false;
        foreach (c; entry.title) if (c < ' ' || c > '~') return false;
        size_t icon;
        while (icon < icons.length && icons[icon] != fields[2]) ++icon;
        if (icon == icons.length) return false;
        entry.icon = cast(Icon) icon;
        int x, y, width, height, instances;
        if (!number(fields[3], -2048, 2048, x) || !number(fields[4], 0, 2048, y)
            || !number(fields[5], 128, 768, width) || !number(fields[6], 80, 520, height)
            || !number(fields[7], 0, maxGuiWindows, instances)) return false;
        entry.bounds = Rect(x, y, width, height);
        entry.fromRight = x < 0;
        entry.cascadeX = 24;
        entry.cascadeY = 29;
        entry.instances = instances;
        if (fields[8] == "-") entry.launchKey = Key.none;
        else if (fields[8] == "F5") entry.launchKey = Key.openFiles;
        else if (fields[8] == "F8") entry.launchKey = Key.newEditor;
        else if (fields[8] == "F9") entry.launchKey = Key.newCounter;
        else return false;
        entry.keyLabel = entry.launchKey == Key.none ? "" : fields[8];
        if (fields[9] == "document")
        {
            if (document) return false;
            document = entry.documents = true;
        }
        else if (fields[9] != "-") return false;
        foreach (ref previous; entries[0 .. count])
            if (previous.executable == entry.executable
                || (entry.launchKey != Key.none && previous.launchKey == entry.launchKey)) return false;
        ++count;
    }
    return header && count != 0;
}

private bool number(const(char)[] text, int low, int high, out int value)
{
    if (!text.length) return false;
    const negative = text[0] == '-';
    if (negative) text = text[1 .. $];
    if (!text.length) return false;
    foreach (c; text)
    {
        if (c < '0' || c > '9' || value > 2048) return false;
        value = value * 10 + c - '0';
    }
    if (negative) value = -value;
    return value >= low && value <= high;
}
