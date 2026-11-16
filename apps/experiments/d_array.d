/// Check that array casts share storage and concatenation creates independent storage, then try a cast with a partial element.
module d_array;

import user_abi : Call;
import user_api : send;

pragma(inline, false) private ushort[] asWords(return scope ubyte[] bytes)
{
    return cast(ushort[]) bytes;
}

pragma(inline, false) private ubyte[] asBytes(return scope ushort[] words)
{
    return cast(ubyte[]) words;
}

pragma(inline, false) private ushort[] joinArrays(ushort[] values, const(ushort)[] suffix)
{
    return values ~ suffix;
}

pragma(inline, false) private ushort[] joinWithElement(ushort[] left, ushort middle, const(ushort)[] right)
{
    return left ~ middle ~ right;
}

private ushort[] compileTimeJoin()
{
    ushort[2] input = [4, 5];
    return _d_arraycatnTX!(ushort[])(input[], cast(ushort) 6, input[0 .. 1]);
}

static assert(compileTimeJoin() == [4, 5, 6, 4]);

void main()
{
    ushort[2] original = [0x1234, 0xabcd];
    auto bytes = asBytes(original[]);
    assert(bytes.length == 4 && bytes.ptr is cast(ubyte*) original.ptr);
    assert(bytes[0] == 0x34 && bytes[3] == 0xab);

    auto words = asWords(bytes);
    assert(words.length == 2 && words.ptr is original.ptr);
    const empty = asWords(bytes[2 .. 2]);
    assert(empty.length == 0 && empty.ptr is original.ptr + 1);
    assert(asWords(null) is null);
    words[0] = 11;
    assert(original[0] == 11);

    const ushort[2] suffix = [23, 34];
    auto combined = joinWithElement(words, 22, suffix[]);
    assert(combined == [11, 0xabcd, 22, 23, 34]);
    combined[0] = 255;
    assert(words[0] == 11);
    assert(joinArrays(null, null) is null);
    auto copied = joinArrays(words, null);
    assert(copied == words && copied.ptr !is words.ptr);

    send(Call.write, "D arrays: casts and concatenation passed.\n");
    auto invalid = asWords(bytes[0 .. 3]);
    if (invalid.length != 0)
        send(Call.write, "Invalid array cast succeeded.\n");
}
