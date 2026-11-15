/// UART上のシェル。Shell.pollで1行を組み立て、dispatchでファイルなどを操作する。
module shell;

import application : launchFile;
import cpu : haltCpu;
import filesystem : FsResult, FileVersion, errorText, fileLimit, isMounted, isText, maxFileBytes,
    maxNameBytes, nameAt, open, remove, save, validFilename;
import boot_info : usableMemoryKiB;
import physical_memory : freeMemoryKiB;
import process : ProcessInfo, exitedProcesses, faultedProcesses, infoAt, infoFor, processLimit,
    processName, spawn, stop;
import user_program : Program, programName;
import serial : flushSerial, tryReadByte, writeByte, writeText;

private enum lineCapacity = 127;
private enum newLine = "\r\n";

nothrow @nogc:

struct Shell
{
    private char[lineCapacity] buffer = void;
    private size_t length;
    private bool skipNextLf;
    private bool overflow;
    private TerminalEscape escape;
    private HexUpload upload;
    private uint foregroundPid;

    nothrow @nogc:

    void start()
    {
        writeText("dlang> ");
    }

    /// 1回に1バイトを処理し、入力待ちの間もGUIが動くようにする。
    void poll()
    {
        if (foregroundPid != 0)
        {
            ProcessInfo info;
            if (infoFor(foregroundPid, info))
                return;
            foregroundPid = 0;
            start();
        }

        char key;
        if (!tryReadByte(key))
            return;

        const completesCrLf = skipNextLf && key == '\n';
        skipNextLf = key == '\r';
        if (completesCrLf)
            return;

        if (upload.active)
        {
            upload.receive(key);
            if (!upload.active)
                start();
            return;
        }

        if (key == '\r' || key == '\n')
        {
            writeText(newLine);
            if (overflow)
                writeText("Line too long (max " ~ lineCapacity.stringof ~ " bytes)." ~ newLine);
            else
                dispatch(buffer[0 .. length], upload, foregroundPid);

            length = 0;
            overflow = false;
            escape = TerminalEscape.init;
            if (!upload.active && foregroundPid == 0)
                start();
            return;
        }

        if (escape.consume(key) || overflow)
            return;

        if (key == '\b' || key == '\x7f')
        {
            if (length > 0)
            {
                --length;
                writeText("\b \b");
            }
        }
        else if (key >= ' ' && key <= '~')
        {
            if (length == buffer.length)
            {
                overflow = true;
                writeByte('\a');
                return;
            }
            buffer[length++] = key;
            writeByte(key);
        }
    }
}

/// putの受信中は通常の行入力と分ける。指定サイズが揃った転送だけを保存する。
private struct HexUpload
{
    bool active;
    private char[maxFileBytes] bytes = void;
    private char[maxNameBytes] filename = void;
    private size_t nameLength, expectedBytes, receivedBytes;
    private FileVersion original;
    private int highNibble;
    private bool invalid, atLineStart;
    private char terminator;

    void begin(scope const(char)[] argument) nothrow @nogc
    {
        size_t split;
        while (split < argument.length && argument[split] != ' ')
            ++split;
        if (split == 0 || split == argument.length)
        {
            writeText("Usage: put NAME BYTES" ~ newLine);
            return;
        }
        const name = argument[0 .. split];
        if (!validFilename(name))
        {
            printResult(FsResult.invalidName, null);
            return;
        }
        auto count = argument[split + 1 .. $];
        while (count.length && count[0] == ' ')
            count = count[1 .. $];
        if (!parseByteCount(count, expectedBytes))
        {
            writeText("Specify a byte count from 0 to 16384." ~ newLine);
            return;
        }

        const(char)[] current;
        const result = open(name, current, original);
        if (result != FsResult.ok && result != FsResult.notFound)
        {
            printResult(result, null);
            return;
        }
        foreach (i, char c; name)
            filename[i] = c;
        nameLength = name.length;
        receivedBytes = 0;
        highNibble = -1;
        invalid = false;
        atLineStart = true;
        terminator = 0;
        active = true;
        writeText("Send hex, then . on its own line. ! cancels." ~ newLine);
    }

    void receive(char key) nothrow @nogc
    {
        if (key == '\r' || key == '\n')
        {
            if (terminator != 0)
                finish();
            atLineStart = true;
            return;
        }
        if (key == ' ' || key == '\t')
            return;
        if (atLineStart && (key == '.' || key == '!'))
        {
            terminator = key;
            atLineStart = false;
            return;
        }
        atLineStart = false;
        const digit = hexValue(key);
        if (digit < 0 || receivedBytes == expectedBytes || terminator != 0)
        {
            terminator = 0;
            invalid = true;
        }
        if (invalid)
            return;
        if (highNibble < 0)
            highNibble = digit;
        else
        {
            bytes[receivedBytes++] = cast(char) (highNibble * 16 + digit);
            highNibble = -1;
        }
    }

    private void finish() nothrow @nogc
    {
        if (terminator == '!')
            writeText("Canceled." ~ newLine);
        else if (invalid || highNibble >= 0 || receivedBytes != expectedBytes)
            writeText("Invalid hex data or byte count. File was not changed." ~ newLine);
        else
            printResult(save(filename[0 .. nameLength], bytes[0 .. receivedBytes], &original), "Saved.");
        active = false;
    }
}

private bool parseByteCount(scope const(char)[] digits, out size_t value)
{
    if (digits.length == 0)
        return false;
    foreach (char c; digits)
    {
        if (c < '0' || c > '9')
            return false;
        value = value * 10 + (c - '0');
        if (value > maxFileBytes)
            return false;
    }
    return true;
}

private int hexValue(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// 矢印キーなどが送るCSI/SS3シーケンスを文字入力と区別する。
private struct TerminalEscape
{
    private enum State { idle, escape, sequence }
    private State state;

    bool consume(char key) nothrow @nogc
    {
        if (key == '\x1b')
        {
            state = State.escape;
            return true;
        }
        if (state == State.sequence)
        {
            if (key >= '\x40' && key <= '\x7e')
                state = State.idle;
            return true;
        }
        if (state == State.escape)
        {
            state = key == '[' || key == 'O' ? State.sequence : State.idle;
            return state == State.sequence;
        }
        return false;
    }
}

private void dispatch(scope const(char)[] line, ref HexUpload upload, ref uint foregroundPid)
{
    while (line.length && line[0] == ' ')
        line = line[1 .. $];
    if (line.length == 0)
        return;

    size_t nameLength;
    while (nameLength < line.length && line[nameLength] != ' ')
        ++nameLength;
    const name = line[0 .. nameLength];
    auto argument = line[nameLength .. $];
    while (argument.length && argument[0] == ' ')
        argument = argument[1 .. $];

    if (sameText(name, "echo"))
    {
        writeText(argument);
        writeText(newLine);
        return;
    }

    if (sameText(name, "help"))
    {
        writeText("help        List commands\r\n"
                ~ "echo TEXT   Print text\r\n"
                ~ "uname       Show OS and CPU architecture\r\n"
                ~ "mem         Show usable memory at boot\r\n"
                ~ "ls          List saved files\r\n"
                ~ "cat NAME    Read a text file\r\n"
                ~ "write NAME TEXT   Create or replace a file\r\n"
                ~ "put NAME BYTES    Receive a file as hex\r\n"
                ~ "get NAME          Send a file as hex\r\n"
                ~ "rm NAME     Delete a file\r\n"
                ~ "run NAME [&]      Execute an ELF from the disk\r\n"
                ~ "spawn TYPE  Start counter, spin, exit or fault\r\n"
                ~ "ps          Show user processes\r\n"
                ~ "kill PID    Stop a user process\r\n"
                ~ "clear       Clear the terminal\r\n"
                ~ "halt        Stop the guest CPU\r\n");
    }
    else if (sameText(name, "uname"))
        writeText("Dlang OS x86_64" ~ newLine);
    else if (sameText(name, "mem"))
        printMemory();
    else if (sameText(name, "ls"))
        listFiles();
    else if (sameText(name, "cat"))
        printFile(argument);
    else if (sameText(name, "write"))
        writeFile(argument);
    else if (sameText(name, "put"))
        upload.begin(argument);
    else if (sameText(name, "get"))
        printFile(argument, true);
    else if (sameText(name, "rm"))
        printResult(remove(argument), "Deleted.");
    else if (sameText(name, "run"))
        runCommand(argument, foregroundPid);
    else if (sameText(name, "spawn"))
        spawnCommand(argument);
    else if (sameText(name, "ps"))
        listProcesses();
    else if (sameText(name, "kill"))
        killCommand(argument);
    else if (sameText(name, "clear"))
        writeText("\x1b[2J\x1b[H");
    else if (sameText(name, "halt"))
    {
        if (argument.length != 0)
        {
            writeText("Usage: halt" ~ newLine);
            return;
        }
        writeText("CPU halted." ~ newLine);
        flushSerial();
        haltCpu();
    }
    else
    {
        writeText("Unknown command: ");
        writeText(name);
        writeText(newLine);
    }
}

private void listFiles()
{
    if (!isMounted())
    {
        printResult(FsResult.unavailable, null);
        return;
    }
    foreach (slot; 0 .. fileLimit)
    {
        const name = nameAt(slot);
        if (name.length)
        {
            writeText(name);
            writeText(newLine);
        }
    }
}

private void printFile(scope const(char)[] name, bool hex = false)
{
    const(char)[] contents;
    FileVersion fileVersion;
    const result = open(name, contents, fileVersion);
    if (result != FsResult.ok)
    {
        printResult(result, null);
        return;
    }

    if (hex)
    {
        writeText("HEX ");
        writeUnsigned(contents.length);
        writeText(newLine);
        enum digits = "0123456789abcdef";
        foreach (i, char c; contents)
        {
            const value = cast(ubyte) c;
            writeByte(digits[value >> 4]);
            writeByte(digits[value & 15]);
            if ((i + 1) % 32 == 0 || i + 1 == contents.length)
                writeText(newLine);
        }
        return;
    }
    if (!isText(contents))
    {
        writeText("Binary file. Use get NAME." ~ newLine);
        return;
    }

    foreach (char c; contents)
    {
        if (c == '\n')
            writeText(newLine);
        else
            writeByte(c);
    }
    if (contents.length && contents[$ - 1] != '\n')
        writeText(newLine);
}

private void writeFile(scope const(char)[] argument)
{
    size_t separator;
    while (separator < argument.length && argument[separator] != ' ')
        ++separator;
    const name = argument[0 .. separator];
    // 名前の後ろの区切り1文字だけを除き、残りの空白は本文に残す。
    const text = separator < argument.length ? argument[separator + 1 .. $] : null;
    printResult(save(name, text), "Saved.");
}

private void printResult(FsResult result, scope const(char)[] success)
{
    writeText(result == FsResult.ok ? success : errorText(result));
    writeText(newLine);
}

private void spawnCommand(scope const(char)[] kind)
{
    static foreach (program; [Program.counter, Program.spin, Program.exit, Program.fault])
    {{
        if (sameText(kind, programName(program)))
        {
            const pid = spawn(program);
            if (pid == 0)
                writeText("Unable to start process." ~ newLine);
            else
            {
                writeText("Started PID ");
                writeUnsigned(pid);
                writeText(newLine);
            }
            return;
        }
    }}
    writeText("Usage: spawn counter|spin|exit|fault" ~ newLine);
}

private void runCommand(scope const(char)[] argument, ref uint foregroundPid)
{
    auto name = argument;
    const background = name.length >= 2 && name[$ - 2] == ' ' && name[$ - 1] == '&';
    if (background)
        name = name[0 .. $ - 2];
    while (name.length && name[$ - 1] == ' ')
        name = name[0 .. $ - 1];
    if (name.length == 0)
    {
        writeText("Usage: run NAME [&]" ~ newLine);
        return;
    }

    uint pid;
    const failure = launchFile(name, pid);
    if (failure.length)
    {
        writeText(failure);
        writeText(newLine);
        return;
    }
    if (background)
    {
        writeText("Started PID ");
        writeUnsigned(pid);
        writeText(newLine);
    }
    else
        foregroundPid = pid;
}

private void listProcesses()
{
    writeText("PID PROGRAM VALUE SLICES PREEMPTIONS" ~ newLine);
    foreach (slot; 0 .. processLimit)
    {
        const task = infoAt(slot);
        if (task.pid == 0)
            continue;
        writeUnsigned(task.pid);
        writeByte(' ');
        writeText(processName(task));
        writeByte(' ');
        writeUnsigned(task.value);
        writeByte(' ');
        writeUnsigned(task.slices);
        writeByte(' ');
        writeUnsigned(task.preemptions);
        writeText(newLine);
    }
    writeText("Exited: ");
    writeUnsigned(exitedProcesses());
    writeText("  Faulted: ");
    writeUnsigned(faultedProcesses());
    writeText(newLine);
}

private void killCommand(scope const(char)[] argument)
{
    uint pid;
    foreach (char c; argument)
    {
        if (c < '0' || c > '9' || pid > (uint.max - (c - '0')) / 10)
        {
            writeText("Usage: kill PID" ~ newLine);
            return;
        }
        pid = pid * 10 + (c - '0');
    }
    if (pid == 0)
        writeText("Usage: kill PID" ~ newLine);
    else
        writeText(stop(pid) ? "Stopped." ~ newLine : "Process not found." ~ newLine);
}

private bool sameText(scope const(char)[] text, scope const(char)[] expected)
{
    if (text.length != expected.length)
        return false;
    foreach (i, character; text)
        if (character != expected[i])
            return false;
    return true;
}

private void printMemory()
{
    writeText("Usable memory: ");
    writeUnsigned(usableMemoryKiB());
    writeText(" KiB" ~ newLine);
    writeText("Free pages: ");
    writeUnsigned(freeMemoryKiB());
    writeText(" KiB" ~ newLine);
}

private void writeUnsigned(ulong value)
{
    char[20] digits = void; // ulongを10進表記したときの最大桁数
    size_t first = digits.length;
    do
    {
        digits[--first] = cast(char) ('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    writeText(digits[first .. $]);
}
