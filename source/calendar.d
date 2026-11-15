/// RTCから受け取る暦と経過秒の計算。validateで入力を検査し、advanceで日付境界を進める。
module calendar;

struct DateTime
{
    ushort year;
    ubyte month, day, hour, minute, second;
}

nothrow @nogc:

uint daysInMonth(uint year, uint month)
{
    if (month == 2) return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28;
    return month == 4 || month == 6 || month == 9 || month == 11 ? 30 : 31;
}

bool validate(DateTime time)
{
    return time.year >= 1900 && time.year <= 9999 && time.month >= 1 && time.month <= 12
        && time.day >= 1 && time.day <= daysInMonth(time.year, time.month)
        && time.hour < 24 && time.minute < 60 && time.second < 60;
}

bool advance(ref DateTime time, ulong seconds)
{
    if (!validate(time)) return false;
    const total = seconds + time.hour * 3600 + time.minute * 60 + time.second;
    time.hour = cast(ubyte) (total % 86400 / 3600);
    time.minute = cast(ubyte) (total % 3600 / 60);
    time.second = cast(ubyte) (total % 60);
    auto days = total / 86400;
    while (days)
    {
        const remaining = daysInMonth(time.year, time.month) - time.day + 1;
        if (days < remaining) { time.day = cast(ubyte) (time.day + days); break; }
        days -= remaining;
        time.day = 1;
        if (++time.month == 13)
        {
            time.month = 1;
            if (++time.year > 9999) return false;
        }
    }
    return true;
}

void digits(char[] target, uint value)
{
    for (size_t i = target.length; i;)
    {
        target[--i] = cast(char) ('0' + value % 10);
        value /= 10;
    }
}

void format(DateTime time, ref char[10] date, ref char[12] clock)
{
    foreach (i, c; "0000-00-00") date[i] = c;
    foreach (i, c; "00:00:00 RTC") clock[i] = c;
    digits(date[0 .. 4], time.year);
    digits(date[5 .. 7], time.month);
    digits(date[8 .. 10], time.day);
    digits(clock[0 .. 2], time.hour);
    digits(clock[3 .. 5], time.minute);
    digits(clock[6 .. 8], time.second);
}
