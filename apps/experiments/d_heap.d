/// newと配列の追加を試し、最後にヒープの上限に達したときの終了を確認する。
module d_heap;

import core.volatile : volatileLoad, volatileStore;
import user_abi : Call, userHeapBase, userHeapBytes;
import user_api : send;

private align(32) struct Record
{
    uint value = 19;
    uint untouched;
}

private class Counter
{
    uint value = 40;

    this(uint increment)
    {
        value += increment;
    }
}

pragma(inline, false) private uint* newNumber(uint value) { return new uint(value); }
pragma(inline, false) private Record* newRecord() { return new Record; }
pragma(inline, false) private Counter newCounter(uint increment) { return new Counter(increment); }
pragma(inline, false) private ubyte[] newBytes(size_t count) pure @safe { return new ubyte[count]; }

private uint[] growArray() pure @safe
{
    auto values = [0u, 1u];
    foreach (i; 2 .. 2048)
        values ~= cast(uint) i;
    return values;
}

private bool inHeap(const(void)* ptr)
{
    const address = cast(size_t) ptr;
    return address >= userHeapBase && address - userHeapBase < userHeapBytes;
}

void main()
{
    auto number = newNumber(42);
    auto record = newRecord();
    auto counter = newCounter(2);
    assert(inHeap(number) && *number == 42);
    assert(inHeap(record) && cast(size_t) record % Record.alignof == 0);
    assert(record.value == 19 && record.untouched == 0);
    assert(inHeap(cast(void*) counter) && counter.value == 42);

    auto bytes = newBytes(4097);
    auto tail = &bytes[$ - 1];
    assert(inHeap(bytes.ptr) && volatileLoad(bytes.ptr) == 0 && volatileLoad(tail) == 0);
    volatileStore(tail, cast(ubyte) 42);
    assert(newBytes(0).length == 0);

    auto records = new Record[2];
    assert(cast(size_t) records.ptr % Record.alignof == 0);
    foreach (ref entry; records)
        assert(entry.value == 19 && entry.untouched == 0);
    records ~= *record;
    assert(records.length == 3 && records[$ - 1].value == 19);

    uint[2] original = [10, 20];
    uint[] values = original[];
    values ~= 30;
    values ~= values[];
    assert(inHeap(values.ptr) && values.length == 6);
    foreach (i, value; values)
        assert(value == 10 * (i % 3 + 1));
    assert(original[0] == 10 && original[1] == 20);

    auto prefix = values[0 .. 2];
    prefix ~= 99;
    assert(prefix.length == 3 && prefix[2] == 99 && values[2] == 30);

    auto growing = growArray();
    foreach (i, value; growing)
        assert(value == i);

    string message;
    message ~= "D heap: new and array append passed.\n";
    assert(inHeap(message.ptr));
    assert(send(Call.write, message) == message.length);

    // 使用済みの領域があるので、ヒープ全体と同じ長さの配列は確保できない。
    auto tooLarge = newBytes(userHeapBytes);
    if (tooLarge.length != 0)
        send(Call.write, "Unexpected successful allocation.\n");
}
