/// Share syscall numbers and ELF process heap bounds between the kernel and applications.
module user_abi;

enum Call : ulong { yield, publish, exit, write, reservedWindowOpen, reservedWindowText, reservedWindowEvent,
    guiPoll, guiPresent, guiDirectory, guiReadFile, guiSaveFile, guiOpenDocument, guiMonitor, guiCreate, heapResize, sleep, guiWait }
enum ulong callError = ulong.max;
enum uint titleLimit = 24;
enum uint writeLimit = 128;
enum size_t userHeapBase = 0x1000_0000;
enum size_t userHeapInitialBytes = 64 * 1024;
// Virtual address range limit. Available RAM determines how much can be allocated.
enum size_t userHeapLimitBytes = 0x6000_0000;

// Infinite wait for guiWait. sleep takes a duration in milliseconds.
enum ulong waitForever = ulong.max;
