/// PhobosでCRC-32を計算し、通常の16進表記で結果をシリアルに出す。
module d_crc;

import std.digest.crc : crc32Of, crcHexString;
import user_abi : Call;
import user_api : send;

pragma(inline, false)
private void printCrc32(const(ubyte)[] input)
{
    send(Call.write, crcHexString(crc32Of(input))[]);
    send(Call.write, "\n");
}

void main()
{
    printCrc32(cast(const(ubyte)[]) "123456789");
    printCrc32(cast(const(ubyte)[]) "The quick brown fox jumps over the lazy dog");
}
