/// PCI configuration mechanism 1で全バスを列挙する。ドライバはクラスとBARを読む。
module pci;

import cpu : readPortDword, writePortDword;

struct PciAddress
{
    ubyte bus, device, functionNumber;

    uint read(ubyte offset) const nothrow @nogc
    {
        const address = 0x8000_0000U | (cast(uint) bus << 16)
            | (cast(uint) device << 11) | (cast(uint) functionNumber << 8) | (offset & 0xfc);
        writePortDword(0xcf8, address);
        return readPortDword(0xcfc);
    }
}

/// falseで列挙を中断する。関数0のmultifunctionビットがある場合だけ関数1〜7を調べる。
bool scanPci(scope bool function(PciAddress) nothrow @nogc visit) nothrow @nogc
{
    foreach (bus; 0 .. 256)
        foreach (device; 0 .. 32)
        {
            auto address = PciAddress(cast(ubyte) bus, cast(ubyte) device, 0);
            if ((address.read(0) & 0xffff) == 0xffff) continue;
            const functions = (address.read(0x0c) & 0x0080_0000) ? 8 : 1;
            foreach (number; 0 .. functions)
            {
                address.functionNumber = cast(ubyte) number;
                if ((address.read(0) & 0xffff) != 0xffff && !visit(address))
                    return false;
            }
        }
    return true;
}
