/// LDC 1.43.0のベアメタルアプリ用の暗黙インポート。起動用のModuleInfoと、
/// 割り当てと例外の型照合に使うTypeInfo、例外のクラス階層と文字列化を定義する。
module object;

alias size_t = typeof(int.sizeof);
alias ptrdiff_t = typeof(cast(void*) 0 - cast(void*) 0);
alias noreturn = typeof(*null);
alias string = immutable(char)[];
alias wstring = immutable(wchar)[];
alias dstring = immutable(dchar)[];

public import core.internal.entrypoint : _d_cmain;
public import core.internal.array.equality : __equals;
public import d_allocation : _d_newitemT, _d_newclassT, _d_newarrayT, _d_newarrayU, _d_newarraymTX,
    _d_arrayliteralTX, _d_arrayappendcTX, _d_arrayappendT, __ArrayCast, _d_arraycatnTX, idup;

enum MIctordone = 0x02, MItlsctor = 0x08, MIctor = 0x20, MIimportedModules = 0x400;
struct ModuleInfo
{
    uint _flags, _index;
}

class Object
{
    string toString() { return typeid(this).name; }
}

class Throwable : Object
{
    interface TraceInfo
    {
        int opApply(scope int delegate(ref const(char[]))) const;
        int opApply(scope int delegate(ref size_t, ref const(char[]))) const;
        string toString() const;
    }

    string msg;
    string file;
    size_t line;
    TraceInfo info;
    Throwable next;

    @safe pure nothrow @nogc this(string msg, Throwable next = null)
    {
        this(msg, null, 0, next);
    }

    @safe pure nothrow @nogc this(string msg, string file, size_t line, Throwable next = null)
    {
        this.msg = msg;
        this.file = file;
        this.line = line;
        this.next = next;
    }

    const(char)[] message() const @safe nothrow { return msg; }

    override string toString()
    {
        string result;
        toString((in part) { result ~= part; });
        return result;
    }

    void toString(scope void delegate(in char[]) sink) const
    {
        import core.internal.string : unsignedToTempString;

        char[20] digits;
        sink(typeid(this).name);
        sink("@");
        sink(file);
        sink("(");
        sink(unsignedToTempString(line, digits[]));
        sink(")");
        if (msg.length != 0)
        {
            sink(": ");
            sink(msg);
        }

        if (info !is null)
        {
            try
            {
                sink("\n----------------");
                foreach (frame; info)
                {
                    sink("\n");
                    sink(frame);
                }
            }
            catch (Throwable)
            {
                // トレースの表示で失敗しても、先に出した例外の説明は残す。
            }
        }
    }
}

class Exception : Throwable
{
    @safe pure nothrow @nogc this(string msg, string file = __FILE__, size_t line = __LINE__,
                                  Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @safe pure nothrow @nogc this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

class Error : Throwable
{
    @safe pure nothrow @nogc this(string msg, Throwable next = null)
    {
        super(msg, next);
    }

    @safe pure nothrow @nogc this(string msg, string file, size_t line, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

// 精密GC用のポインタマップを生成しない。
enum immutable(void)* RTInfo(T) = null;

class TypeInfo
{
    override string toString() const @safe { return typeid(this).name; }
    @property size_t tsize() const { return 0; }
    @property size_t talign() const { return tsize; }
    const(void)[] initializer() const { return null; }
    @property const(TypeInfo) next() const { return null; }
    size_t getHash(scope const void* value) @trusted pure nothrow const { return 0; }
}

// 以下のフィールド順はLDCがELFに出力するTypeInfoのレイアウトに対応する。
class TypeInfo_Class : TypeInfo
{
    byte[] m_init;
    string name;
    void*[] vtbl;
    Interface[] interfaces;
    TypeInfo_Class base;
    void* destructor;
    void function(Object) classInvariant;
    ushort m_flags, depth;
    void* deallocator;
    OffsetTypeInfo[] m_offTi;
    void function(Object) defaultConstructor;
    immutable(void)* m_RTInfo;
    uint[4] nameSig;

    override string toString() const @safe { return name; }
    override @property size_t tsize() const { return Object.sizeof; }
}

class TypeInfo_Interface : TypeInfo
{
    TypeInfo_Class info;

    override string toString() const @safe { return info.name; }
    override @property size_t tsize() const { return Object.sizeof; }
}

struct Interface
{
    TypeInfo_Class classinfo;
    void*[] vtbl;
    size_t offset;
}

struct OffsetTypeInfo
{
    size_t offset;
    TypeInfo ti;
}

class TypeInfo_Struct : TypeInfo
{
    string mangledName;
    void[] m_init;
    void* xtoHash, xopEquals, xopCmp, xtoString;
    uint m_flags;
    union
    {
        void function(void*) xdtor;
        void function(void*, const TypeInfo_Struct) xdtorti;
    }
    void* xpostblit;
    uint m_align;
    TypeInfo m_arg1, m_arg2;
    immutable(void)* m_RTInfo;

    override @property size_t tsize() const { return m_init.length; }
    override @property size_t talign() const { return m_align; }
    override const(void)[] initializer() const { return m_init; }
}

class TypeInfo_Enum : TypeInfo
{
    TypeInfo base;
    string name;
    void[] m_init;

    override @property size_t tsize() const { return base.tsize; }
    override @property size_t talign() const { return base.talign; }
    override const(void)[] initializer() const { return m_init.length == 0 ? base.initializer() : m_init; }
}

class TypeInfo_Pointer : TypeInfo
{
    TypeInfo value;

    override @property size_t tsize() const { return (void*).sizeof; }
    override @property const(TypeInfo) next() const { return value; }
}

class TypeInfo_Array : TypeInfo
{
    TypeInfo value;

    override @property size_t tsize() const { return (void[]).sizeof; }
    override @property size_t talign() const { return (void[]).alignof; }
    override @property const(TypeInfo) next() const { return value; }
}

class TypeInfo_StaticArray : TypeInfo
{
    TypeInfo value;
    size_t len;

    override @property size_t tsize() const { return value.tsize * len; }
    override @property size_t talign() const { return value.talign; }
    override const(void)[] initializer() const { return value.initializer(); }
    override @property const(TypeInfo) next() const { return value; }
}

class TypeInfo_Const : TypeInfo
{
    TypeInfo base;

    override @property size_t tsize() const { return base.tsize; }
    override @property size_t talign() const { return base.talign; }
    override const(void)[] initializer() const { return base.initializer(); }
    override @property const(TypeInfo) next() const { return base.next; }
}

class TypeInfo_Invariant : TypeInfo_Const {}
class TypeInfo_Shared : TypeInfo_Const {}
class TypeInfo_Inout : TypeInfo_Const {}

private mixin template ScalarInfo(T)
{
    override @property size_t tsize() const { return T.sizeof; }
    override @property size_t talign() const { return T.alignof; }

    override const(void)[] initializer() const
    {
        static if (!__traits(isZeroInit, T))
        {
            static immutable T initial = T.init;
            return (cast(const(void)*) &initial)[0 .. T.sizeof];
        }
        else
            return null;
    }
}

private mixin template ArrayInfo(T)
{
    override @property const(TypeInfo) next() const { return typeid(T); }
}

private template Types(T...) { alias Types = T; }

// 組み込み型はLDCがTypeInfo_<型のマングル名>.__initZを直接参照する。
static foreach (T; Types!(bool, byte, ubyte, short, ushort, int, uint, long, ulong,
        char, wchar, dchar, float, double, real))
{
    mixin("final class TypeInfo_" ~ T.mangleof ~ " : TypeInfo { mixin ScalarInfo!" ~ T.stringof ~ "; }");
    mixin("final class TypeInfo_A" ~ T.mangleof ~ " : TypeInfo_Array { mixin ArrayInfo!" ~ T.stringof ~ "; }");
}

final class TypeInfo_v : TypeInfo
{
    override @property size_t tsize() const { return 1; }
}

final class TypeInfo_Av : TypeInfo_Array { mixin ArrayInfo!void; }
final class TypeInfo_Aya : TypeInfo_Array { mixin ArrayInfo!(immutable char); }
final class TypeInfo_Ayu : TypeInfo_Array { mixin ArrayInfo!(immutable wchar); }
final class TypeInfo_Ayw : TypeInfo_Array { mixin ArrayInfo!(immutable dchar); }

// コンパイラが比較できない構造体のTypeInfoに入れるフォールバック。
bool _xopEquals(in void*, in void*) { assert(0, "No struct equality operation"); }
int _xopCmp(in void*, in void*) { assert(0, "No struct comparison operation"); }
