/// Compute SHA-256 with Phobos and print the result in hexadecimal to the serial console.
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
    // Process a full 64-byte block, then handle the remaining bytes and padding.
    enum longInput = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
                   ~ "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
    printSha256(cast(const(ubyte)[]) longInput);
}
