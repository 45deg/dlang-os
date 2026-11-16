/// Dependency constructors must precede the importing module; destructors run in reverse order.
module druntime_dependency;
import user_abi : Call;
import user_api : send;
__gshared int sharedOrder;
int threadOrder;
shared static this() { sharedOrder = 1; }
static this() { assert(sharedOrder == 2); threadOrder = 1; }
static ~this() { assert(threadOrder == 3); send(Call.write, "Dependency TLS destructor passed.\n"); }
shared static ~this() { assert(sharedOrder == 3); send(Call.write, "Dependency shared destructor passed.\n"); }
