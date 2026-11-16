/// Evaluate arithmetic from on-screen buttons or keyboard input using six decimal places of fixed-point precision.
module calculator;

import desktop_theme : accent, centeredText, divider, ink, muted, paper, toolbar, warning;
import graphics : Rect, Screen;
import numbers : decimalText;
import ps2 : Key;

private enum long scale = 1_000_000;
private enum long largest = 999_999_999_999;
private immutable long[7] powersOfTen = [1, 10, 100, 1_000, 10_000, 100_000, scale];
private enum Error { none, divideByZero, outOfRange }

private struct Entry
{
    long digits;
    size_t places;
    bool point;
    bool negative;

    nothrow @nogc:

    void append(int digit)
    {
        if (point && places == 6)
            return;
        const nextPlaces = places + point;
        const nextDigits = digits * 10 + digit;
        if (nextDigits >= scale * powersOfTen[nextPlaces])
            return;
        digits = nextDigits;
        places = nextPlaces;
    }

    void erase()
    {
        if (places)
            --places;
        else if (point)
        {
            point = false;
            return;
        }
        digits /= 10;
    }

    long value() const
    {
        const magnitude = digits * powersOfTen[6 - places];
        return negative ? -magnitude : magnitude;
    }
}

struct Calculator
{
    private Entry entry;
    private long result;
    private char pending = 0;
    private bool entering;
    private Error error;

    nothrow @nogc:

    void keyPress(Key key)
    {
        if (key == Key.enter)
            press('=');
        else if (key == Key.backspace || key == Key.deleteKey)
            press('\b');
        else if (key == Key.escape)
            press('c');
        else if (key >= ' ' && key <= '~')
            press(cast(char) key);
    }

    void click(Rect body, int x, int y)
    {
        foreach (i, action; actions)
            if (keyBounds(body, i).contains(x, y))
            {
                press(action);
                return;
            }
    }

    private void press(char key)
    {
        if (key == 'c' || key == 'C')
        {
            this = Calculator.init;
            return;
        }
        if ((key >= '0' && key <= '9') || key == '.')
        {
            if (error != Error.none)
                this = Calculator.init;
            if (!entering)
            {
                entry = Entry.init;
                entering = true;
            }
            if (key == '.')
                entry.point = true;
            else
                entry.append(key - '0');
            return;
        }
        if (error != Error.none)
            return;

        switch (key)
        {
            case '\b':
                if (entering)
                    entry.erase();
                break;
            case 'n', 'N':
                if (entering)
                    entry.negative = !entry.negative;
                else if (pending)
                {
                    entry = Entry.init;
                    entry.negative = true;
                    entering = true;
                }
                else
                    result = -result;
                break;
            case '+', '-', '*', '/', '=':
                if (entering)
                {
                    if (pending)
                        calculate(entry.value());
                    else
                        result = entry.value();
                    entering = false;
                }
                pending = key == '=' || error != Error.none ? 0 : key;
                break;
            default: break;
        }
    }

    private void calculate(long right)
    {
        long value;
        switch (pending)
        {
            case '+': value = result + right; break;
            case '-': value = result - right; break;
            case '*':
                // Split the operands into integer and fractional parts to avoid multiplying two scaled values directly.
                value = (result / scale) * right + (result % scale) * (right / scale)
                    + (result % scale) * (right % scale) / scale;
                break;
            case '/':
                if (right == 0)
                {
                    error = Error.divideByZero;
                    return;
                }
                value = result * scale / right;
                break;
            default: return;
        }
        if (value < -largest || value > largest)
        {
            error = Error.outOfRange;
            return;
        }
        result = value;
    }

    void draw(ref Screen screen, Rect body) const
    {
        screen.fill(body, toolbar);
        const display = Rect(body.x + 11, body.y + 11, body.width - 22, 61);
        screen.fill(display, paper);
        screen.fill(Rect(display.x, display.y + display.height - 1, display.width, 1), divider);

        char[20] displayBuffer = void;
        const text = error == Error.divideByZero ? "Divide by zero"
            : error == Error.outOfRange ? "Out of range"
            : entering ? formatted(entry.value(), entry.places, entry.point, entry.negative, displayBuffer)
            : formatted(result, resultPrecision(result), false, false, displayBuffer);
        const magnification = error == Error.none ? 2 : 1;
        screen.text(display.x + display.width - 9 - cast(int) text.length * 8 * magnification,
            display.y + 31, text, error == Error.none ? ink : warning, magnification);
        if (pending)
        {
            char[20] prior = void;
            const previous = formatted(result, resultPrecision(result), false, false, prior);
            screen.text(display.x + 9, display.y + 10, previous, muted);
            screen.character(display.x + 19 + cast(int) previous.length * 8, display.y + 10, pending, muted);
        }

        foreach (i, action; actions)
        {
            const rect = keyBounds(body, i);
            const operation = i < 4 || i % 4 == 3;
            const selected = pending != 0 && action == pending && !entering;
            screen.fill(rect, action == '=' || selected ? accent : operation ? divider : paper);
            centeredText(screen, rect, labels[i], action == '=' || selected ? paper : ink);
        }
    }
}

private enum actions = "c\bn/789*456-123+0.=";
private immutable string[19] labels = [
    "C", "DEL", "+/-", "/", "7", "8", "9", "*", "4", "5", "6", "-", "1", "2", "3", "+", "0", ".", "=",
];
static assert(actions.length == labels.length);

private Rect keyBounds(Rect body, size_t index) pure nothrow @nogc
{
    const spacing = (body.width - 16) / 4;
    return Rect(body.x + 10 + cast(int) (index % 4) * spacing,
        body.y + 82 + cast(int) (index / 4) * 38,
        (index == actions.length - 1 ? 2 * spacing : spacing) - 4, 32);
}

private size_t resultPrecision(long value) pure nothrow @nogc
{
    size_t places = 6;
    while (places != 0 && value % 10 == 0)
    {
        --places;
        value /= 10;
    }
    return places;
}

private const(char)[] formatted(long value, size_t places, bool point, bool negativeZero,
                                return ref char[20] buffer) pure nothrow @nogc
{
    const magnitude = cast(ulong) (value < 0 ? -value : value);
    char[20] integerBuffer = void;
    const whole = decimalText(magnitude / scale, integerBuffer);
    size_t length;
    if (value < 0 || negativeZero)
        buffer[length++] = '-';
    foreach (char c; whole)
        buffer[length++] = c;

    if (places || point)
    {
        buffer[length++] = '.';
        ulong fraction = magnitude % scale;
        foreach (_; 0 .. places)
        {
            fraction *= 10;
            buffer[length++] = cast(char) ('0' + fraction / scale);
            fraction %= scale;
        }
    }
    return buffer[0 .. length];
}
