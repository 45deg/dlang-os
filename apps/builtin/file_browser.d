/// Filesの一覧と選択を管理する。refreshでディスクの一覧を読み直し、keyPressとclickで開くファイル名を返す。
module file_browser;

import desktop_theme : accent, accentLight, button, ink, labelWithin, muted, paper, toolbar;
import app_files : generation, isMounted, nameAt, refreshDirectory;
import file_api : fileLimit;
import graphics : Rect, Screen;
import ps2 : Key;

private enum int fileRowHeight = 16;

struct FileBrowser
{
    private size_t[fileLimit] fileSlots;
    private size_t fileCount;
    private size_t selectedFile;
    private ulong seenGeneration;

    nothrow @nogc:

    void refresh()
    {
        refreshDirectory();
        const previous = fileCount > 0 ? fileSlots[selectedFile] : fileLimit;
        fileCount = 0;
        foreach (slot; 0 .. fileLimit)
            if (nameAt(slot).length)
                fileSlots[fileCount++] = slot;
        if (fileCount == 0 || selectedFile >= fileCount)
            selectedFile = 0;
        foreach (i; 0 .. fileCount)
            if (fileSlots[i] == previous)
                selectedFile = i;
        seenGeneration = generation();
    }

    bool refreshIfChanged()
    {
        if (seenGeneration == generation())
            return false;
        refresh();
        return true;
    }

    const(char)[] keyPress(Key key)
    {
        if (key == Key.up && selectedFile > 0)
            --selectedFile;
        else if (key == Key.down && selectedFile + 1 < fileCount)
            ++selectedFile;
        else if (key == Key.enter)
            return selectedName();
        return null;
    }

    const(char)[] click(Rect body, int x, int y)
    {
        if (openButton(body).contains(x, y))
            return selectedName();

        const items = Rect(body.x + 8, body.y + 46, body.width - 16, cast(int) fileCount * fileRowHeight);
        if (items.contains(x, y))
            selectedFile = cast(size_t) ((y - items.y) / fileRowHeight);
        return null;
    }

    void draw(ref Screen screen, Rect body) const
    {
        screen.fill(body, paper);
        screen.fill(Rect(body.x, body.y, body.width, 41), toolbar);
        button(screen, openButton(body), "Open", fileCount != 0);
        screen.text(body.x + 72, body.y + 17, "Select a file, then Open", muted);
        if (fileCount == 0)
            screen.text(body.x + 12, body.y + 54, isMounted() ? "No saved files" : "Data disk unavailable", muted);
        foreach (i; 0 .. fileCount)
        {
            const row = Rect(body.x + 8, body.y + 46 + cast(int) i * fileRowHeight, body.width - 16, fileRowHeight);
            if (i == selectedFile)
            {
                screen.fill(row, accentLight);
                labelWithin(screen, Rect(row.x + 5, row.y, 8, row.height), ">", accent);
            }
            labelWithin(screen, Rect(row.x + 19, row.y, row.width - 19, row.height), nameAt(fileSlots[i]), ink);
        }
    }

    private const(char)[] selectedName() const
    {
        return fileCount == 0 ? null : nameAt(fileSlots[selectedFile]);
    }

    private Rect openButton(Rect body) const
    {
        return Rect(body.x + 10, body.y + 9, 52, 24);
    }
}
