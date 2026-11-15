/// ローカルAPICのワンショット割り込みで、ユーザープロセスの実行時間を区切る。
module apic_timer;

import address_space : mapLocalApic;
import core.volatile : volatileStore;
import cpu : readMsr, writeMsr;
import privilege : timerVector;

private enum uint baseMsr = 0x1b;
private enum uint endOfInterrupt = 0x0b0;
private enum uint taskPriority = 0x080;
private enum uint spurious = 0x0f0;
private enum uint timerConfig = 0x320;
private enum uint initialCount = 0x380;
private enum uint divideConfig = 0x3e0;
private enum uint maskInterrupt = 1 << 16;
private enum uint quantumTicks = 100_000;

private __gshared uint* registers;
private __gshared bool x2Apic;

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
    writeRegister(taskPriority, 0);
    writeRegister(spurious, 0x1ff);
    writeRegister(timerConfig, maskInterrupt | timerVector);
    writeRegister(initialCount, 0);
    writeRegister(divideConfig, 0x03); // APICの基準クロックの1/16
    writeRegister(timerConfig, timerVector);
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
