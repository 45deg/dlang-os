/// Bound user-process execution time with local APIC one-shot interrupts.
module apic_timer;

import address_space : mapLocalApic;
import core.volatile : volatileStore, volatileLoad;
import clock : milliseconds;
import cpu : readMsr, writeMsr;
import privilege : timerVector, waitForInterrupt;

private enum uint baseMsr = 0x1b;
private enum uint endOfInterrupt = 0x0b0;
private enum uint taskPriority = 0x080;
private enum uint spurious = 0x0f0;
private enum uint timerConfig = 0x320;
private enum uint initialCount = 0x380;
private enum uint divideConfig = 0x3e0;
private enum uint maskInterrupt = 1 << 16;
private __gshared uint quantumTicks;

private __gshared uint* registers;
private __gshared bool x2Apic, available;

nothrow @nogc:

bool initTimer()
{
    const base = readMsr(baseMsr);
    if (!(base & (1UL << 11)))
        return false;

    x2Apic = (base & (1UL << 10)) != 0;
    if (!x2Apic)
    {
        registers = mapLocalApic(base & 0x000f_ffff_ffff_f000);
        if (registers is null)
            return false;
    }
    // Set LINT0 to ExtINT to receive IRQ4 from the PIC.
    writeRegister(0x350, 0x700);
    writeRegister(taskPriority, 0);
    writeRegister(spurious, 0x1ff);
    writeRegister(timerConfig, maskInterrupt | timerVector);
    writeRegister(initialCount, 0);
    writeRegister(divideConfig, 0x03); // Divide the APIC base clock by 16.
    writeRegister(initialCount, uint.max);
    const started = milliseconds();
    while (milliseconds() - started < 20) {}
    const elapsed = uint.max - readRegister(0x390);
    writeRegister(initialCount, 0);
    quantumTicks = elapsed / 4; // 5 ms time slice.
    if (quantumTicks == 0 || elapsed == uint.max)
        return false;
    writeRegister(timerConfig, timerVector);
    available = true;
    return true;
}

void arm()
{
    writeRegister(initialCount, quantumTicks);
}

void cancel(bool timerDelivered)
{
    writeRegister(initialCount, 0);
    if (timerDelivered)
        writeRegister(endOfInterrupt, 0);
}

private void writeRegister(uint offset, uint value)
{
    if (x2Apic)
        writeMsr(0x800 + offset / 16, value);
    else
        volatileStore(registers + offset / uint.sizeof, value);
}

private uint readRegister(uint offset)
{
    return x2Apic ? cast(uint) readMsr(0x800 + offset / 16)
                  : volatileLoad(registers + offset / uint.sizeof);
}

/// PS/2 input uses polling, so return to the kernel within about 1 ms.
void idle()
{
    if (!available) return;
    const ticks = quantumTicks / 5;
    writeRegister(initialCount, ticks == 0 ? 1 : ticks);
    const delivered = waitForInterrupt();
    cancel(delivered);
}
