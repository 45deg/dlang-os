/// d_initより先に共有コンストラクタで初期値を設定する。
module d_init_dependency;

shared uint initialValue;

shared static this()
{
    initialValue = 41;
}
