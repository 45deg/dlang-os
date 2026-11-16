/// Set the initial value in a shared constructor before d_init runs.
module d_init_dependency;

shared uint initialValue;

shared static this()
{
    initialValue = 41;
}
