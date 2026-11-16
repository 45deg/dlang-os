/// Verify type matching, exception formatting, cleanup across calls, and exit on an uncaught exception.
module d_exception;

import user_abi : Call;
import user_api : send;

private class SampleException : Exception
{
    this(string msg, Throwable previous)
    {
        super(msg, previous, "sample.d", 17);
    }
}

private __gshared uint cleanup;

private void verifyFormatting(Throwable thrown)
{
    enum expected = "d_exception.SampleException@sample.d(17): sample";
    Object asObject = thrown;
    assert(asObject.toString() == expected);

    size_t offset;
    const(Throwable) view = thrown;
    view.toString((in part) {
        assert(part == expected[offset .. offset + part.length]);
        offset += part.length;
    });
    assert(offset == expected.length);
}

pragma(inline, false) private void raise(Throwable thrown)
{
    throw thrown;
}

pragma(inline, false) private void relay(Throwable thrown)
{
    scope(exit) cleanup = cleanup * 10 + 1;
    raise(thrown);
}

pragma(inline, false) private void skipErrorHandler(Throwable thrown)
{
    try
        relay(thrown);
    catch (Error)
        assert(0);
    finally
        cleanup = cleanup * 10 + 2;
}

void main()
{
    auto cause = new Exception("cause");
    auto failure = new SampleException("sample", cause);
    try
    {
        try
            skipErrorHandler(failure);
        catch (Exception e)
        {
            assert(e is failure && e.next is cause && cleanup == 12);
            cleanup = 123;
            throw e;
        }
    }
    catch (SampleException e)
    {
        assert(e is failure && e.msg == "sample" && e.file == "sample.d" && e.line == 17);
        assert(cleanup == 123);
        verifyFormatting(e);
        cleanup = 1234;
    }

    try
        relay(new Error("fatal"));
    catch (Exception)
        assert(0);
    catch (Throwable e)
    {
        assert(e.msg == "fatal" && cleanup == 12341);
        cleanup = 0;
    }
    assert(cleanup == 0);
    send(Call.write, "D exceptions: catches and cleanups passed.\n");
    raise(new Exception("unhandled"));
}
