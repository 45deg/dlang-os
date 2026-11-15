/// システムコールとELFプロセスのヒープ範囲をカーネルとアプリで共有する。
module user_abi;

enum Call : ulong { yield, publish, exit, write, windowOpen, windowText, windowEvent,
    guiPoll, guiPresent, guiDirectory, guiReadFile, guiSaveFile, guiOpenDocument, guiMonitor }
enum WindowEvent : ulong { none, activate, close }
enum ulong callError = ulong.max;
enum uint titleLimit = 24;
enum uint textLimit = 28;
enum uint writeLimit = 128;
enum size_t userHeapBase = 0x0041_2000;
enum size_t userHeapBytes = 64 * 1024;
