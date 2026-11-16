/// Run the upstream Phobos writeln through standard druntime startup.
module phobos_hello;
import std.stdio : writeln;

void main()
{
    writeln("Hello, world!");
}
