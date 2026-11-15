/// 依存モジュールと自身の共有コンストラクタの結果をmainで確認し、シリアルに出す。
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
