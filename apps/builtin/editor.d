/// Keep the draft for one editor window. loadDocument and saveDocument interface with DlangFS.
module editor;

import desktop_theme : accent, accentLight, button, centeredText, divider, ink, labelWithin, muted, paper,
    toolbar, warning;
import app_files : documentBuffer, isMounted, open, save;
import file_api : FsResult, FileVersion, errorText, fileLimit, isText, maxNameBytes, maxFileBytes, validFilename;
import font : largeTextHeight, largeTextWidth;
import graphics : Rect, Screen, maximum, minimum;
import ps2 : Key;

private enum int lineHeight = largeTextHeight + 2;
private enum int cellWidth = largeTextWidth;
private enum NameMode { inactive, create, saveCopy }

enum EditorClick { none, select, scroll, close }

struct Editor
{
    private NameMode nameMode;
    // Show the first invalid character so the user can see when the name exceeds the limit.
    private char[maxNameBytes + 1] nameInput = void;
    private size_t inputLength;
    private size_t nameCaret;

    private char[maxNameBytes] documentName = void;
    private size_t documentNameLength;
    private size_t length;
    private size_t caret;
    private size_t anchor;
    private size_t firstVisibleRow;
    private bool revealCaret = true;
    private FileVersion fileVersion;
    private bool dirty;
    private bool confirmDiscard;
    private bool closeAfterDiscard;
    private const(char)[] message;

    nothrow @nogc:

    private @property char[] document() const
    {
        return documentBuffer();
    }

    bool unsaved() const
    {
        return dirty || nameMode != NameMode.inactive;
    }

    const(char)[] title() const return
    {
        return documentNameLength != 0 ? documentName[0 .. documentNameLength] : "Text editor";
    }

    void openDocument(scope const(char)[] name)
    {
        if (unsaved())
            return;
        const(char)[] contents;
        FileVersion stored;
        const result = open(name, contents, stored);
        if (result != FsResult.ok)
            message = errorText(result);
        else if (!isText(contents))
            message = "Binary file. Open a text document.";
        else if (stored.slot != fileVersion.slot || stored.sequence != fileVersion.sequence)
            loadDocument(name, contents, stored);
    }

    void keepOpen()
    {
        if (nameMode != NameMode.inactive)
            message = "Finish or cancel the name entry before closing.";
        else
        {
            confirmDiscard = true;
            closeAfterDiscard = true;
        }
    }

    bool keyPress(Key key)
    {
        if (confirmDiscard && key != Key.discard)
        {
            confirmDiscard = false;
            closeAfterDiscard = false;
            message = null;
        }
        if (nameMode != NameMode.inactive)
        {
            editName(key);
            return false;
        }

        switch (key)
        {
            case Key.newFile:
                if (dirty)
                    message = "Save changes or press F6 to discard them.";
                else
                    startNaming(NameMode.create);
                break;
            case Key.save:
                if (documentNameLength != 0 && dirty)
                    saveDocument(documentName[0 .. documentNameLength], fileVersion);
                break;
            case Key.saveAs:
                if (documentNameLength != 0)
                    startNaming(NameMode.saveCopy);
                break;
            case Key.discard:
                if (dirty && confirmDiscard)
                    return confirmDiscardChanges();
                confirmDiscard = dirty;
                break;
            default:
                if (documentNameLength != 0)
                    editDocument(key);
                break;
        }
        return false;
    }

    EditorClick click(Rect body, int x, int y)
    {
        if (nameMode != NameMode.inactive)
        {
            if (confirmButton(body).contains(x, y))
                confirmName();
            else if (cancelButton(body).contains(x, y))
                cancelNaming();
            else if (nameField(body).contains(x, y))
            {
                const offset = maximum(0, x - nameField(body).x - 8 + 4);
                nameCaret = minimum(cast(int) inputLength, offset / 8);
            }
            return EditorClick.none;
        }
        if (confirmDiscard)
        {
            if (discardButton(body).contains(x, y))
                return confirmDiscardChanges() ? EditorClick.close : EditorClick.none;
            confirmDiscard = false;
            closeAfterDiscard = false;
            if (keepButton(body).contains(x, y))
                return EditorClick.none;
        }
        if (newButton(body).contains(x, y))
            keyPress(Key.newFile);
        else if (saveButton(body).contains(x, y))
            keyPress(Key.save);
        else if (copyButton(body).contains(x, y))
            keyPress(Key.saveAs);
        else if (documentNameLength != 0)
        {
            const area = documentArea(body);
            if (area.contains(x, y))
            {
                caret = indexAt(area, x, y);
                anchor = caret;
                return EditorClick.select;
            }
            if (scrollbar(body).contains(x, y))
            {
                scrollPointer(body, y);
                return EditorClick.scroll;
            }
        }
        return EditorClick.none;
    }

    private Rect newButton(Rect body) const { return Rect(body.x + 10, body.y + 8, 48, 24); }
    private Rect saveButton(Rect body) const { return Rect(body.x + 65, body.y + 8, 52, 24); }
    private Rect copyButton(Rect body) const { return Rect(body.x + 124, body.y + 8, 70, 24); }
    private Rect confirmButton(Rect body) const { return Rect(body.x + 14, body.y + 162, 103, 28); }
    private Rect cancelButton(Rect body) const { return Rect(body.x + 127, body.y + 162, 74, 28); }
    private Rect discardButton(Rect body) const
    {
        return Rect(body.x + body.width - 158, body.y + body.height - 21, 72, 19);
    }
    private Rect keepButton(Rect body) const
    {
        return Rect(body.x + body.width - 78, body.y + body.height - 21, 64, 19);
    }
    private Rect nameField(Rect body) const
    {
        return Rect(body.x + 14, body.y + 89, body.width - 28, 29);
    }

    private void startNaming(NameMode mode)
    {
        if (!isMounted())
        {
            message = errorText(FsResult.unavailable);
            return;
        }
        nameMode = mode;
        inputLength = 0;
        nameCaret = 0;
        message = null;
    }

    private void editName(Key key)
    {
        if (key == Key.escape)
            cancelNaming();
        else if (key == Key.enter)
            confirmName();
        else if (key == Key.left && nameCaret > 0)
            --nameCaret;
        else if (key == Key.right && nameCaret < inputLength)
            ++nameCaret;
        else if ((key == Key.backspace && nameCaret > 0) || (key == Key.deleteKey && nameCaret < inputLength))
        {
            if (key == Key.backspace)
                --nameCaret;
            foreach (i; nameCaret .. inputLength - 1)
                nameInput[i] = nameInput[i + 1];
            --inputLength;
            message = null;
        }
        else if (key >= ' ' && key <= '~')
        {
            if (inputLength < nameInput.length)
            {
                for (size_t i = inputLength; i > nameCaret; --i)
                    nameInput[i] = nameInput[i - 1];
                nameInput[nameCaret++] = cast(char) key;
                ++inputLength;
            }
            message = inputLength > maxNameBytes ? "Name is too long. Use up to 24 characters." : null;
        }
    }

    private void cancelNaming()
    {
        nameMode = NameMode.inactive;
        message = null;
    }

    private void confirmName()
    {
        const name = nameInput[0 .. inputLength];
        if (!validFilename(name))
        {
            message = inputLength > maxNameBytes ? "Name is too long. Use up to 24 characters."
                : "Use 1-24 letters, digits, . _ - (no leading dot).";
            return;
        }
        if (nameMode == NameMode.saveCopy)
        {
            saveDocument(name, FileVersion.init);
            return;
        }

        FileVersion existing;
        const(char)[] text;
        const result = open(name, text, existing);
        if (result != FsResult.notFound)
        {
            message = result == FsResult.ok ? "Name in use. Choose another name." : errorText(result);
            return;
        }
        loadDocument(name, null, FileVersion.init);
        dirty = true;
    }

    void loadDocument(scope const(char)[] name, scope const(char)[] contents, FileVersion stored)
    {
        foreach (i, char c; name)
            documentName[i] = c;
        documentNameLength = name.length;
        foreach (i, char c; contents)
            document[i] = c;
        length = contents.length;
        caret = length;
        anchor = caret;
        firstVisibleRow = 0;
        revealCaret = true;
        fileVersion = stored;
        dirty = false;
        confirmDiscard = false;
        closeAfterDiscard = false;
        nameMode = NameMode.inactive;
        message = null;
    }

    private void saveDocument(scope const(char)[] name, FileVersion expected)
    {
        FileVersion stored;
        const result = save(name, document[0 .. length], expected, stored);
        if (result != FsResult.ok)
        {
            if (result == FsResult.conflict)
                message = nameMode == NameMode.saveCopy || expected.slot == fileLimit
                    ? "Name in use. Choose another name."
                    : "File changed on disk. Use Save As.";
            else
                message = errorText(result);
            return;
        }

        fileVersion = stored;
        if (nameMode == NameMode.saveCopy)
        {
            foreach (i, char c; name)
                documentName[i] = c;
            documentNameLength = name.length;
        }
        dirty = false;
        nameMode = NameMode.inactive;
        message = errorText(FsResult.ok);
    }

    private bool confirmDiscardChanges()
    {
        const close = closeAfterDiscard;
        const(char)[] contents;
        FileVersion stored;
        if (fileVersion.slot != fileLimit
            && open(documentName[0 .. documentNameLength], contents, stored) == FsResult.ok
            && isText(contents))
        {
            foreach (i, char c; contents)
                document[i] = c;
            length = contents.length;
            caret = length;
            anchor = caret;
            revealCaret = true;
            fileVersion = stored;
        }
        else
        {
            documentNameLength = 0;
            length = 0;
            caret = 0;
            anchor = 0;
        }
        dirty = false;
        confirmDiscard = false;
        closeAfterDiscard = false;
        message = "Changes discarded.";
        return close;
    }

    private void editDocument(Key key)
    {
        const start = selectedStart();
        const end = selectedEnd();
        if (key == Key.left || key == Key.right)
        {
            if (start != end)
                caret = key == Key.left ? start : end;
            else if (key == Key.left && caret > 0)
                --caret;
            else if (key == Key.right && caret < length)
                ++caret;
            anchor = caret;
            revealCaret = true;
        }
        else if (key == Key.backspace || key == Key.deleteKey)
            replaceText(key == Key.backspace && start == end && start > 0 ? start - 1 : start,
                key == Key.deleteKey && start == end && end < length ? end + 1 : end, null);
        else if (key == Key.enter || (key >= ' ' && key <= '~'))
        {
            char[1] text = [key == Key.enter ? '\n' : cast(char) key];
            replaceText(start, end, text[]);
        }
    }

    private size_t selectedStart() const { return anchor < caret ? anchor : caret; }
    private size_t selectedEnd() const { return anchor < caret ? caret : anchor; }

    private void replaceText(size_t start, size_t end, scope const(char)[] replacement)
    {
        if (start == end && replacement.length == 0)
            return;
        const nextLength = start + replacement.length + length - end;
        if (nextLength > document.length)
        {
            message = errorText(FsResult.tooLarge);
            return;
        }
        const tail = start + replacement.length;
        if (tail < end)
            foreach (i; 0 .. length - end)
                document[tail + i] = document[end + i];
        else if (tail > end)
            for (size_t i = length - end; i > 0; --i)
                document[tail + i - 1] = document[end + i - 1];
        foreach (i, char c; replacement)
            document[start + i] = c;
        length = nextLength;
        caret = tail;
        anchor = caret;
        revealCaret = true;
        dirty = true;
        message = null;
    }

    private Rect documentArea(Rect body) const
    {
        const height = (body.height - 109) / lineHeight * lineHeight;
        return Rect(body.x + 14, body.y + 82, body.width - 46, height);
    }

    private Rect scrollbar(Rect body) const
    {
        const area = documentArea(body);
        return Rect(body.x + body.width - 25, area.y, 13, area.height);
    }

    private size_t lastRow(size_t index, size_t columns) const
    {
        size_t row;
        size_t column;
        foreach (i; 0 .. index)
            advance(document[i], columns, row, column);
        return row;
    }

    private size_t maxScroll(Rect area) const
    {
        const rows = lastRow(length, area.width / cellWidth) + 1;
        const visible = area.height / lineHeight;
        return rows > visible ? rows - visible : 0;
    }

    private size_t indexAt(Rect area, int x, int y) const
    {
        const columns = area.width / cellWidth;
        const targetColumn = minimum(columns, maximum(0, x - area.x + cellWidth / 2) / cellWidth);
        const visibleRow = maximum(0, minimum(area.height - 1, y - area.y)) / lineHeight;
        const targetRow = firstVisibleRow + visibleRow;
        size_t row;
        size_t column;
        foreach (i; 0 .. length)
        {
            if (row == targetRow && (column >= targetColumn || document[i] == '\n'))
                return i;
            const previousRow = row;
            advance(document[i], columns, row, column);
            if (previousRow == targetRow && row != previousRow)
                return i + 1; // End of a soft-wrapped line.
        }
        return length;
    }

    bool dragSelection(Rect body, int x, int y)
    {
        const area = documentArea(body);
        const before = firstVisibleRow;
        if (y < area.y && firstVisibleRow > 0)
            --firstVisibleRow;
        else if (y >= area.y + area.height && firstVisibleRow < maxScroll(area))
            ++firstVisibleRow;
        const next = indexAt(area, x, y);
        const changed = caret != next || firstVisibleRow != before;
        caret = next;
        return changed;
    }

    bool scrollPointer(Rect body, int y)
    {
        const track = scrollbar(body);
        const last = maxScroll(documentArea(body));
        const offset = maximum(0, minimum(track.height - 1, y - track.y));
        const next = (offset * last + (track.height - 1) / 2) / (track.height - 1);
        const changed = next != firstVisibleRow;
        firstVisibleRow = next;
        revealCaret = false;
        return changed;
    }

    void draw(ref Screen screen, Rect body, bool active)
    {
        screen.fill(body, paper);
        screen.fill(Rect(body.x, body.y, body.width, 40), toolbar);
        const naming = nameMode != NameMode.inactive;
        button(screen, newButton(body), "New", !naming && isMounted());
        button(screen, saveButton(body), "Save", !naming && isMounted() && dirty);
        button(screen, copyButton(body), "Save As", !naming && isMounted() && documentNameLength != 0);

        const x = body.x + 14;
        const bottom = body.y + body.height - 23;
        screen.fill(Rect(body.x, bottom, body.width, 23), toolbar);
        if (confirmDiscard)
        {
            labelWithin(screen, Rect(x, bottom, body.width - 185, 23),
                closeAfterDiscard ? "Discard changes and close?" : "Discard changes?", warning);
            const discard = discardButton(body);
            screen.fill(discard, warning);
            centeredText(screen, discard, "Discard", paper);
            button(screen, keepButton(body), "Keep");
        }
        else
        {
            labelWithin(screen, Rect(x, bottom, body.width - 28, 23),
                message.length != 0 ? message : naming ? "Enter Confirm name   Esc Cancel" : "",
                naming && message.length != 0 ? warning : muted);
        }

        if (naming)
        {
            screen.text(x, body.y + 58, nameMode == NameMode.create ? "New file" : "Save as", ink, 2);
            screen.fill(nameField(body), accentLight);
            screen.text(x + 8, body.y + 100, nameInput[0 .. inputLength], ink);
            if (active)
                screen.fill(Rect(x + 8 + cast(int) nameCaret * 8, body.y + 98, 2, 14), accent);
            screen.text(x, body.y + 130, "1-24 letters, digits, . _ - (no leading dot)", muted);
            button(screen, confirmButton(body), nameMode == NameMode.create ? "Create" : "Save copy",
                validFilename(nameInput[0 .. inputLength]) && isMounted());
            const cancel = cancelButton(body);
            screen.fill(cancel, toolbar);
            centeredText(screen, cancel, "Cancel", ink);
            return;
        }
        if (documentNameLength == 0)
        {
            screen.text(x, body.y + 63, "Use New, or open a file from Files.", muted);
            return;
        }

        if (dirty)
            screen.text(x, body.y + 53, "Unsaved changes", warning);
        else if (documentIsCurrent())
            screen.text(x, body.y + 53, "Saved", accent);
        else
            screen.text(x, body.y + 53, "Changed on disk. Reopen from Files.", warning);

        screen.fill(Rect(body.x, body.y + 71, body.width, 1), divider);
        const area = documentArea(body);
        drawDocument(screen, area, active);
        drawScrollbar(screen, scrollbar(body), area);
    }

    private bool documentIsCurrent() const
    {
        FileVersion current;
        const(char)[] contents;
        return open(documentName[0 .. documentNameLength], contents, current) == FsResult.ok
            && current.slot == fileVersion.slot && current.sequence == fileVersion.sequence;
    }

    private void drawDocument(ref Screen screen, Rect area, bool showCaret)
    {
        const columns = cast(size_t) (area.width / cellWidth);
        const visibleRows = cast(size_t) (area.height / lineHeight);
        if (revealCaret)
        {
            const caretRow = lastRow(caret, columns);
            if (caretRow < firstVisibleRow)
                firstVisibleRow = caretRow;
            else if (caretRow - firstVisibleRow >= visibleRows)
                firstVisibleRow = caretRow - visibleRows + 1;
            revealCaret = false;
        }
        const last = maxScroll(area);
        if (firstVisibleRow > last)
            firstVisibleRow = last;

        const start = selectedStart();
        const end = selectedEnd();
        size_t row;
        size_t column;
        foreach (i; 0 .. length + 1)
        {
            if (row >= firstVisibleRow + visibleRows)
                break;
            if (row >= firstVisibleRow)
            {
                const x = area.x + cast(int) column * cellWidth;
                const y = area.y + cast(int) (row - firstVisibleRow) * lineHeight;
                if (i >= start && i < end)
                    screen.fill(Rect(x, y, cellWidth, lineHeight), accentLight);
                if (i < length)
                    screen.character(x, y, document[i], ink, 2);
                if (i == caret && showCaret)
                    screen.fill(Rect(x, y + largeTextHeight, cellWidth - 2, 2), accent);
            }
            if (i < length)
                advance(document[i], columns, row, column);
        }
    }

    private void drawScrollbar(ref Screen screen, Rect track, Rect area)
    {
        const last = maxScroll(area);
        screen.fill(track, toolbar);
        if (last == 0)
            return;
        const visible = area.height / lineHeight;
        const height = maximum(14, cast(int) (track.height * visible / (visible + last)));
        const y = track.y + cast(int) ((track.height - height) * firstVisibleRow / last);
        screen.fill(Rect(track.x + 2, y, track.width - 4, height), muted);
    }
}

private void advance(char c, size_t columns, ref size_t row, ref size_t column) nothrow @nogc
{
    if (c == '\n' || ++column == columns)
    {
        ++row;
        column = 0;
    }
}
