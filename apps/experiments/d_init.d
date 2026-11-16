/// Check the effects of this module's and its dependency's shared constructors in main and report the result over serial.
module d_init;

import d_init_dependency : initialValue;
import user_abi : Call;
import user_api : send;

private shared uint value;

shared static this()
{
    value = value + initialValue + 1;
}

void main()
{
    if (value == 42)
        send(Call.write, "D shared static constructors ran before main.\n");
    else
        send(Call.write, "D shared static constructors ran out of order or failed.\n");
}
