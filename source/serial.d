/// COM1のUART。受信IRQでリングバッファへ取り込み、シェルがtryReadByteで消費する。
module serial;

import cpu : readPort, writePort;

private enum ushort com1 = 0x3f8;
private enum ushort dataPort = com1;
private enum ushort interruptEnable = com1 + 1;
private enum ushort fifoControl = com1 + 2;
private enum ushort lineControl = com1 + 3;
private enum ushort modemControl = com1 + 4;
private enum ushort lineStatus = com1 + 5;

// DLABが立っている間、先頭2ポートはデータや割り込みではなく分周値を指す。
private enum ushort divisorLow = com1;
private enum ushort divisorHigh = com1 + 1;
private enum ubyte divisorLatchAccess = 0x80;
private enum ubyte eightBitsNoParityOneStopBit = 0x03;
private enum ubyte receiveReady = 0x01;
private enum ubyte transmitReady = 0x20;
private enum ubyte transmitIdle = 0x40;

private __gshared char[4096] receivedBytes;
private __gshared size_t readIndex, receivedCount;
private __gshared bool interruptsEnabled;

nothrow @nogc:

void initSerial()
{
    writePort(lineControl, eightBitsNoParityOneStopBit);
    writePort(interruptEnable, 0);
    writePort(lineControl, divisorLatchAccess);
    // COM1の基準レートは115200 baud。分周値1でそのまま使う。
    writePort(divisorLow, 1);
    writePort(divisorHigh, 0);
    writePort(lineControl, eightBitsNoParityOneStopBit);
    writePort(fifoControl, 0x07); // FIFOを有効にし、送受信バッファを空にする
    writePort(modemControl, 0x03); // DTRとRTSを立てる
}

// IDTとPICのIRQ4経路を準備してから呼ぶ。
void enableReceiveInterrupts()
{
    interruptsEnabled = true;
    writePort(modemControl, 0x0b); // OUT2でPCのIRQ線を有効にする。
    writePort(interruptEnable, 1);
}

extern(C) void serialReceiveInterrupt()
{
    while (receivedCount < receivedBytes.length && (readPort(lineStatus) & receiveReady))
    {
        receivedBytes[(readIndex + receivedCount) % receivedBytes.length] = cast(char) readPort(dataPort);
        ++receivedCount;
    }
    if (receivedCount == receivedBytes.length)
        writePort(interruptEnable, 0); // 消費再開までIRQの連発を止める。
    writePort(0x20, 0x20); // PIC IRQ4のEOI。ExtINTはAPICのISRを使わない。
}

/// カーネルのIF=0で呼ぶ。IRQとの間でリングバッファ更新を直列化する。
bool tryReadByte(out char received)
{
    if (receivedCount != 0)
    {
        received = receivedBytes[readIndex];
        readIndex = (readIndex + 1) % receivedBytes.length;
        --receivedCount;
        if (interruptsEnabled) writePort(interruptEnable, 1);
        return true;
    }
    if ((readPort(lineStatus) & receiveReady) == 0)
        return false;
    received = cast(char) readPort(dataPort);
    return true;
}

void writeByte(char byteToSend)
{
    while ((readPort(lineStatus) & transmitReady) == 0)
    {
    }
    writePort(dataPort, cast(ubyte) byteToSend);
}

void writeText(scope const(char)[] text)
{
    foreach (char byteToSend; text)
        writeByte(byteToSend);
}

/// UARTが最後のバイトを送信し終えるまで待つ。
void flushSerial()
{
    while ((readPort(lineStatus) & transmitIdle) == 0)
    {
    }
}
