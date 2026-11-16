/// Exercise upstream stream reuse, UTF-8, array-backed output and real output errors and closure.
module phobos_output;
import std.stdio : writeln, stdout;
import std.exception : ErrnoException;
import c = core.stdc.stdio;
import core.stdc.errno : EIO;

void main()
{
    writeln("UTF-8: 日本語");
    char[] line;
    foreach (i; 0 .. 300) line ~= cast(char) ('a' + i % 26);
    writeln(line);
    writeln();
    writeln("Repeated output passed.");
    bool caught;
    try { writeln("\x01"); }
    catch (ErrnoException error)
    {
        assert(error.errno == EIO);
        caught = true;
    }
    assert(caught);
    stdout.close();
    caught = false;
    try { writeln("This must not appear."); }
    catch (Exception error) { caught = true; }
    assert(caught);
    assert(c.fputs("Closed-stream error passed.\n", c.stderr) >= 0);
}
