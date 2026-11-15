/// システムコールとELFプロセスのヒープ範囲をカーネルとアプリで共有する。
module user_abi;

enum Call : ulong { yield, publish, exit, write, reservedWindowOpen, reservedWindowText, reservedWindowEvent,
    guiPoll, guiPresent, guiDirectory, guiReadFile, guiSaveFile, guiOpenDocument, guiMonitor, guiCreate, heapResize, sleep, guiWait }
enum ulong callError = ulong.max;
enum uint titleLimit = 24;
enum uint writeLimit = 128;
enum size_t userHeapBase = 0x1000_0000;
enum size_t userHeapInitialBytes = 64 * 1024;
// 仮想領域の上限。実際に確保できる量は空きRAMによる。
enum size_t userHeapLimitBytes = 0x6000_0000;

// guiWaitの無期限待機。sleepはミリ秒数を受け取る。
enum ulong waitForever = ulong.max;
