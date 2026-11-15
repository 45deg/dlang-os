/// PhobosでSHA-256を計算し、16進表記で結果をシリアルに出す。
module d_sha;

import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import user_abi : Call;
import user_api : send;

pragma(inline, false)
private void printSha256(const(ubyte)[] input)
{
    send(Call.write, toHexString!(LetterCase.lower)(sha256Of(input))[]);
    send(Call.write, "\n");
}

void main()
{
    printSha256(cast(const(ubyte)[]) "abc");
    // 64バイトのブロックを処理した後、残りとパディングを扱う。
    enum longInput = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
                   ~ "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
    printSha256(cast(const(ubyte)[]) longInput);
}
