/// Enumerate available block drivers. Currently registers PCI IDE ATA PIO devices.
module storage;

import ata : discoverAta;
import block_device : BlockDevice;

private __gshared BlockDevice[32] disks;
private __gshared size_t diskCount;

bool initStorage() nothrow @nogc
{
    diskCount = 0;
    return discoverAta(disks[], diskCount);
}

BlockDevice[] blockDevices() nothrow @nogc
{
    return disks[0 .. diskCount];
}
