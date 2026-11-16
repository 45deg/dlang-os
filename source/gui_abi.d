/// Define input events, draw lists, and read-only snapshots exchanged by Ring 3 apps and the desktop.
module gui_abi;

import file_api : FileVersion, fileLimit, maxFileBytes, maxNameBytes;
import user_abi : titleLimit;

enum maxGuiWindows = 7;
enum maxProcesses = 8 + maxGuiWindows;

enum GuiEvent : ubyte { none, key, click, drag, release, close, openDocument }

// Structures returned by the kernel have no padding.
struct GuiInput
{
    align(1):
    GuiEvent event;
    bool focused;
    bool mounted;
    ushort key;
    short x, y;
    ushort width, height;
    ulong now; // Milliseconds since boot.
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

// On successful save, set the top bit, encode the slot in the remaining high bits, and return the generation in the low 32 bits.
enum ulong savedVersion = 1UL << 63;
