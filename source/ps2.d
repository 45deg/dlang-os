/// i8042の受信バイトをキーボードのキーとマウスの移動・ボタンに変換する。
module ps2;

import clock : milliseconds;

import cpu : readPort, writePort;

enum Key : ushort
{
    none = 0,
    backspace = 8, tab = 9, enter = 10, escape = 27, deleteKey = 127,
    left = 256, right, up, down, newFile, save, saveAs, discard,
    openFiles, cycleWindow, newEditor, newCounter, closeWindow, appsMenu,
}

struct MouseEvent
{
    int dx;
    int dy;
    bool leftDown;
}

enum InputKind { none, keyboard, mouse }

struct InputEvent
{
    InputKind kind;
    Key key;
    MouseEvent mouse;
}

private enum ushort dataPort = 0x60;
private enum ushort commandPort = 0x64; // 読み出し時はステータス
private enum ubyte outputFull = 0x01;
private enum ubyte inputFull = 0x02;
private enum ubyte fromMouse = 0x20;
private enum ubyte timeoutOrParity = 0xc0;

struct Ps2
{
    private bool active;
    private bool auxiliaryActive;
    private bool extended;
    private ubyte pauseBytes;
    private ubyte shiftKeys;
    private ubyte controlKeys;
    private bool capsLock;
    private bool discardKeyDown;
    private ubyte[3] packet;
    private uint packetLength;

    nothrow @nogc:

    bool init()
    {
        if (!command(0xad) || !command(0xa7))
            return false;
        foreach (_; 0 .. 32)
        {
            if ((readPort(commandPort) & outputFull) == 0)
                break;
            readPort(dataPort);
        }

        ubyte config;
        if (!command(0x20) || !readReply(false, config)
            || !command(0x60) || !sendData(cast(ubyte) ((config | 0x40) & ~0x03))
            || !command(0xae))
            return false;

        // キーボードはSet 2、i8042の変換を通ったSet 1を受信する。
        if (!deviceCommand(false, 0xf5) || !deviceCommand(false, 0xf0)
            || !deviceCommand(false, 2) || !deviceCommand(false, 0xf4))
            return false;

        auxiliaryActive = command(0xa8) && deviceCommand(true, 0xf6)
            && deviceCommand(true, 0xf4);
        active = true;
        return true;
    }

    bool hasPendingInput() const
    {
        return active && (readPort(commandPort) & outputFull) != 0;
    }

    InputEvent poll()
    {
        if (!active)
            return InputEvent.init;
        const status = readPort(commandPort);
        if ((status & outputFull) == 0)
            return InputEvent.init;
        const value = readPort(dataPort);
        if (status & timeoutOrParity)
        {
            packetLength = 0;
            extended = false;
            pauseBytes = 0;
            shiftKeys = 0;
            controlKeys = 0;
            discardKeyDown = false;
            return InputEvent.init;
        }
        if (status & fromMouse)
            return auxiliaryActive ? decodeMouse(value) : InputEvent.init;

        const key = decodeKey(value);
        return key == Key.none ? InputEvent.init : InputEvent(InputKind.keyboard, key);
    }

    private Key decodeKey(ubyte value)
    {
        if (pauseBytes > 0)
        {
            --pauseBytes;
            return Key.none;
        }
        if (value == 0xe1)
        {
            pauseBytes = 5;
            extended = false;
            return Key.none;
        }
        if (value == 0xe0)
        {
            extended = true;
            return Key.none;
        }

        const wasExtended = extended;
        extended = false;
        const released = (value & 0x80) != 0;
        const code = value & 0x7f;
        if (!wasExtended && (code == 0x2a || code == 0x36))
        {
            setModifier(shiftKeys, code == 0x2a ? 1 : 2, released);
            return Key.none;
        }
        if (code == 0x1d)
        {
            setModifier(controlKeys, wasExtended ? 2 : 1, released);
            return Key.none;
        }
        if (!wasExtended && code == 0x40)
        {
            // F6を押し続けても、破棄の確認を2回通過しないようにする。
            const pressed = !released && !discardKeyDown;
            discardKeyDown = !released;
            return pressed ? Key.discard : Key.none;
        }
        if (released)
            return Key.none;

        if (wasExtended)
        {
            switch (code)
            {
                case 0x1c: return Key.enter;
                case 0x48: return Key.up;
                case 0x4b: return Key.left;
                case 0x4d: return Key.right;
                case 0x50: return Key.down;
                case 0x53: return Key.deleteKey;
                default: return Key.none;
            }
        }

        switch (code)
        {
            case 0x01: return Key.escape;
            case 0x0e: return Key.backspace;
            case 0x0f: return Key.tab;
            case 0x1c: return Key.enter;
            case 0x3a: capsLock = !capsLock; return Key.none;
            case 0x3b: return Key.appsMenu; // F1
            case 0x3c: return Key.newFile; // F2
            case 0x3d: return Key.save;    // F3
            case 0x3e: return Key.saveAs;  // F4
            case 0x3f: return Key.openFiles; // F5
            case 0x41: return Key.cycleWindow; // F7
            case 0x42: return Key.newEditor;   // F8
            case 0x43: return Key.newCounter;  // F9
            case 0x44: return Key.closeWindow; // F10
            default: break;
        }
        if (controlKeys != 0)
        {
            switch (code)
            {
                case 0x1f: return shiftKeys != 0 ? Key.saveAs : Key.save;
                default: return Key.none;
            }
        }

        static immutable plain = [
            "1234567890-=", "qwertyuiop[]", "asdfghjkl;'\x60", "\\zxcvbnm,./", " ",
        ];
        static immutable shifted = [
            "!@#$%^&*()_+", "QWERTYUIOP{}", "ASDFGHJKL:\"~", "|ZXCVBNM<>?", " ",
        ];
        static immutable uint[5] starts = [0x02, 0x10, 0x1e, 0x2b, 0x39];
        foreach (row, start; starts)
        {
            if (code < start || code >= start + plain[row].length)
                continue;
            const column = code - start;
            const lower = plain[row][column];
            const isLetter = lower >= 'a' && lower <= 'z';
            const upper = (shiftKeys != 0) != (isLetter && capsLock);
            return cast(Key) (upper ? shifted[row][column] : lower);
        }
        return Key.none;
    }

    private InputEvent decodeMouse(ubyte value)
    {
        if (packetLength == 0 && (value & 0x08) == 0)
            return InputEvent.init;
        packet[packetLength++] = value;
        if (packetLength != 3)
            return InputEvent.init;
        packetLength = 0;

        const flags = packet[0];
        // PS/2のYは上が正。オーバーフロー時は移動を捨ててもボタン状態は渡す。
        const dx = (flags & 0x40) ? 0 : cast(int) packet[1] - ((flags & 0x10) ? 256 : 0);
        const dy = (flags & 0x80) ? 0 : ((flags & 0x20) ? 256 : 0) - cast(int) packet[2];
        return InputEvent(InputKind.mouse, Key.none, MouseEvent(dx, dy, (flags & 1) != 0));
    }
}

private nothrow @nogc:

void setModifier(ref ubyte keys, ubyte mask, bool released)
{
    if (released)
        keys &= ~mask;
    else
        keys |= mask;
}

bool command(ubyte value)
{
    if (!waitInputSpace())
        return false;
    writePort(commandPort, value);
    return true;
}

bool sendData(ubyte value)
{
    if (!waitInputSpace())
        return false;
    writePort(dataPort, value);
    return true;
}

bool waitInputSpace()
{
    const started = milliseconds();
    while (milliseconds() - started < 100)
        if ((readPort(commandPort) & inputFull) == 0)
            return true;
    return false;
}

bool readReply(bool mouse, out ubyte value)
{
    const started = milliseconds();
    while (milliseconds() - started < 100)
    {
        const status = readPort(commandPort);
        if ((status & outputFull) == 0)
            continue;
        const byteValue = readPort(dataPort);
        if (((status & fromMouse) != 0) == mouse && (status & timeoutOrParity) == 0)
        {
            value = byteValue;
            return true;
        }
    }
    return false;
}

bool deviceCommand(bool mouse, ubyte value)
{
    ubyte reply;
    return (!mouse || command(0xd4)) && sendData(value) && readReply(mouse, reply) && reply == 0xfa;
}
