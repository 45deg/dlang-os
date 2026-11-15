/// Ring 3アプリとデスクトップが交換する入力イベント、描画一覧、読み取り用スナップショット。
module gui_abi;

import file_api : FileVersion, fileLimit, maxFileBytes, maxNameBytes;
import user_abi : titleLimit;

enum maxGuiWindows = 7;
enum maxProcesses = 8 + maxGuiWindows;

enum GuiEvent : ubyte { none, key, click, drag, release, close, openDocument }

// カーネルから返す構造体はパディングを持たせない。
struct GuiInput
{
    align(1):
    GuiEvent event;
    bool focused;
    bool mounted;
    ushort key;
    short x, y;
    ushort width, height;
    ulong now; // 起動後のミリ秒
    ulong diskGeneration;
    char[maxNameBytes] filename;
    ubyte filenameLength;
}

struct DrawCommand
{
    short x, y, width, height;
    uint color;
    ushort textOffset, textLength;
}

struct GuiFrame
{
    ushort commandCount, textCount;
    ubyte titleLength, dirty;
    char[titleLimit] title;
    DrawCommand[1024] commands;
    char[4096] text;
}

struct DirectoryEntry
{
    char[maxNameBytes] name;
    ubyte length;
}

alias DirectorySnapshot = DirectoryEntry[fileLimit];

struct ProcessRow
{
    align(1):
    ulong slices, preemptions;
    uint pid;
    char[maxNameBytes] name;
    ubyte nameLength;
}

struct MonitorSnapshot
{
    align(1):
    ulong memoryKiB, exited, faulted;
    uint capacity, running;
    ProcessRow[maxProcesses] rows;
}

struct FileRequest
{
    align(1):
    FileVersion fileVersion;
    uint length, nameLength;
    char[maxNameBytes] name;
}

struct FileTransfer
{
    FileRequest request;
    char[maxFileBytes] data;
}

// 保存成功時は最上位ビットを立て、残りの上位ビットにスロット、下位32ビットに世代番号を返す。
enum ulong savedVersion = 1UL << 63;
