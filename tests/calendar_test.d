/// 暦の境界、入力検証、表示形式をホスト上で検証する。
module calendar_test;
import calendar;
extern(C) int main() nothrow @nogc
{
    assert(!validate(DateTime(2025, 2, 29)));
    assert(!validate(DateTime(2024, 0, 1)));
    assert(!validate(DateTime(2024, 1, 1, 24)));
    assert(!validate(DateTime(1900, 2, 29)));
    auto time = DateTime(2024, 2, 28, 23, 59, 59);
    assert(advance(time, 1));
    assert(time == DateTime(2024, 2, 29));
    assert(advance(time, 86400));
    assert(time == DateTime(2024, 3, 1));
    time = DateTime(2100, 2, 28, 23, 59, 59);
    assert(advance(time, 1) && time == DateTime(2100, 3, 1));
    time = DateTime(2000, 2, 28);
    assert(advance(time, 86400) && time == DateTime(2000, 2, 29));
    time = DateTime(2026, 12, 31, 23, 59, 59);
    assert(advance(time, 1) && time == DateTime(2027, 1, 1));
    time = DateTime(9999, 12, 31, 23, 59, 59);
    assert(!advance(time, 1));
    char[10] date;
    char[8] clock;
    format(DateTime(2024, 2, 29, 3, 4, 5), date, clock);
    assert(date[] == "2024-02-29" && clock[] == "03:04:05");
    return 0;
}
