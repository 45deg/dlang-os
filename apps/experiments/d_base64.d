/// Encode bytes as Base64 with Phobos and print the result to the serial console.
module d_base64;

import std.base64 : Base64;
import user_abi : Call;
import user_api : send;

pragma(inline, false)
private void printBase64(const(ubyte)[] input)
{
    send(Call.write, Base64.encode(input));
    send(Call.write, "\n");
}

void main()
{
    printBase64(cast(const(ubyte)[]) "foobar");
    printBase64(cast(const(ubyte)[]) "fo");
    printBase64(cast(const(ubyte)[]) "f");
}
