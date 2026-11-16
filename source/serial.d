/// Receive COM1 bytes into a ring buffer from the IRQ handler. The shell consumes them through tryReadByte.
module serial;

import cpu : readPort, writePort;

private enum ushort com1 = 0x3f8;
private enum ushort dataPort = com1;
private enum ushort interruptEnable = com1 + 1;
private enum ushort fifoControl = com1 + 2;
private enum ushort lineControl = com1 + 3;
private enum ushort modemControl = com1 + 4;
private enum ushort lineStatus = com1 + 5;

// When DLAB is set, the first two ports access the baud divisor instead of data and interrupt control.
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
    // Use a divisor of 1 for the COM1 base rate of 115200 baud.
    writePort(divisorLow, 1);
    writePort(divisorHigh, 0);
    writePort(lineControl, eightBitsNoParityOneStopBit);
    writePort(fifoControl, 0x07); // Enable FIFO and clear both transmit and receive buffers.
    writePort(modemControl, 0x03); // Assert DTR and RTS.
}

// Call after setting up the IDT and routing IRQ4 through the PIC.
void enableReceiveInterrupts()
{
    interruptsEnabled = true;
    writePort(modemControl, 0x0b); // Use OUT2 to enable the PC IRQ line.
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
        writePort(interruptEnable, 0); // Suppress repeated IRQs until the reader resumes draining the buffer.
    writePort(0x20, 0x20); // Send EOI for PIC IRQ4. ExtINT does not use the APIC's ISR.
}

/// Call in the kernel with IF=0 to serialize ring buffer updates with the IRQ handler.
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

/// Wait for the UART to finish transmitting the last byte.
void flushSerial()
{
    while ((readPort(lineStatus) & transmitIdle) == 0)
    {
    }
}
