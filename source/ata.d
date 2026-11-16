/// Probe PCI IDE channels and both drives with IDENTIFY. Register 512-byte LBA28 ATA PIO devices.
module ata;

import block_device : BlockDevice, Sector, sectorBytes;
import clock : milliseconds;
import cpu : readPort, writePort, readPortWord, writePortWord;
import pci : PciAddress, scanPci;

private enum ubyte busy = 0x80, ready = 0x40, dataReady = 0x08, deviceFaultOrError = 0x21;

private struct Drive
{
    ushort base, control;
    ubyte select;
    ulong sectors;

    nothrow @nogc:

    ushort port(ushort offset) const { return cast(ushort) (base + offset); }
    void settle() { foreach (_; 0 .. 4) readPort(control); }

    bool waitStatus(ubyte required, ubyte forbidden, bool checkErrors = true)
    {
        const started = milliseconds();
        while (milliseconds() - started < 100)
        {
            const status = readPort(control);
            if (status == 0 || status == 0xff) return false;
            if (status & busy) continue;
            if (checkErrors && (status & deviceFaultOrError)) return false;
            if ((status & required) == required && (status & forbidden) == 0) return true;
        }
        return false;
    }

    bool identify()
    {
        writePort(control, 2); // Set nIEN. Data transfer uses polling.
        writePort(port(6), select);
        settle();
        foreach (ushort offset; 2 .. 6) writePort(port(offset), 0);
        writePort(port(7), 0xec);
        settle();
        if (!waitStatus(dataReady, 0) || readPort(port(4)) != 0 || readPort(port(5)) != 0)
            return false; // Also excludes ATAPI devices.
        Sector identity;
        foreach (ref word; identity) word = readPortWord(base);
        settle();
        if (!waitStatus(ready, dataReady) || !(identity[49] & (1 << 9))) return false;
        // If valid IDENTIFY word 106 reports a longer logical sector, reject the drive.
        if ((identity[106] & 0xc000) == 0x4000 && (identity[106] & 0x1000)
            && (cast(uint) identity[117] | (cast(uint) identity[118] << 16)) != sectorBytes / 2)
            return false;
        // Require FLUSH CACHE so a successful write means the data is persistent.
        if ((identity[83] & 0xc000) != 0x4000 || !(identity[83] & (1 << 12))) return false;
        sectors = cast(uint) identity[60] | (cast(uint) identity[61] << 16);
        if (sectors > 0x1000_0000) sectors = 0x1000_0000;
        return sectors != 0;
    }

    bool transfer(ulong lba, ubyte command)
    {
        if (lba >= sectors) return false;
        writePort(port(6), cast(ubyte) (select | 0x40 | (lba >> 24)));
        settle();
        if (!waitStatus(ready, dataReady, false)) return false;
        writePort(port(2), 1);
        writePort(port(3), cast(ubyte) lba);
        writePort(port(4), cast(ubyte) (lba >> 8));
        writePort(port(5), cast(ubyte) (lba >> 16));
        writePort(port(7), command);
        settle();
        return waitStatus(dataReady, 0);
    }
}

private __gshared Drive[32] drives;
private __gshared BlockDevice[] output;
private __gshared size_t count;

nothrow @nogc:

bool discoverAta(BlockDevice[] devices, out size_t found)
{
    output = devices;
    count = 0;
    const complete = scanPci(&inspectController);
    found = count;
    output = null;
    return complete;
}

private bool inspectController(PciAddress address)
{
    const classInfo = address.read(8);
    if ((classInfo >> 16) != 0x0101 || !(address.read(4) & 1)) return true;
    const mode = cast(ubyte) (classInfo >> 8);
    foreach (channel; 0 .. 2)
    {
        ushort base, control;
        if (mode & (1 << (channel * 2)))
        {
            const commandBar = address.read(cast(ubyte) (0x10 + channel * 8));
            const controlBar = address.read(cast(ubyte) (0x14 + channel * 8));
            if (!(commandBar & 1) || !(controlBar & 1)
                || (commandBar & ~3U) == 0 || (commandBar & ~3U) > 0xfff8
                || (controlBar & ~3U) == 0 || (controlBar & ~3U) > 0xfffc)
                continue;
            base = cast(ushort) (commandBar & ~3U);
            control = cast(ushort) ((controlBar & ~3U) + 2);
        }
        else
        {
            // PCI IDE compatibility mode uses fixed ports. Native mode obtains ports from the BARs.
            base = cast(ushort) (channel == 0 ? 0x1f0 : 0x170);
            control = cast(ushort) (channel == 0 ? 0x3f6 : 0x376);
        }
        foreach (unit; 0 .. 2)
        {
            Drive candidate = Drive(base, control, cast(ubyte) (0xa0 | (unit << 4)));
            bool duplicate;
            foreach (ref known; drives[0 .. count])
                if (known.base == base && known.control == control && known.select == candidate.select)
                    duplicate = true;
            if (duplicate || !candidate.identify()) continue;
            if (count == drives.length || count == output.length) return false;
            drives[count] = candidate;
            output[count] = BlockDevice(candidate.sectors, &drives[count], &readBlock, &writeBlock);
            ++count;
        }
    }
    return true;
}

private bool readBlock(void* context, ulong lba, out Sector sector)
{
    auto drive = cast(Drive*) context;
    if (!drive.transfer(lba, 0x20)) return false;
    foreach (ref word; sector) word = readPortWord(drive.base);
    drive.settle();
    return drive.waitStatus(ready, dataReady);
}

private bool writeBlock(void* context, ulong lba, ref const Sector sector)
{
    auto drive = cast(Drive*) context;
    if (!drive.transfer(lba, 0x30)) return false;
    foreach (word; sector) writePortWord(drive.base, word);
    drive.settle();
    if (!drive.waitStatus(ready, dataReady)) return false;
    writePort(drive.port(7), 0xe7);
    drive.settle();
    return drive.waitStatus(ready, dataReady);
}
