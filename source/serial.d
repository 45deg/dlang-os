/// COM1のUART。initSerialで通信条件を設定し、ポーリングで1バイトずつ送受信する。
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

bool tryReadByte(out char received)
{
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
