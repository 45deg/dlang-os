/// スネークの盤面と進行状態を保持する。advanceで1マス進み、drawで窓に描画する。
module snake;

import desktop_theme : button, centeredText, ink, muted, paper, toolbar;
import graphics : Rect, Screen;
import numbers : decimalText;
import ps2 : Key;

private enum columns = 20;
private enum rows = 13;
private enum cells = columns * rows;
private enum cellSize = 15;
private enum initialLength = 3;
private enum ulong stepTicks = 360_000_000;

private enum Direction { right, down, left, up }
private enum Phase { idle, playing, paused, lost, won }

struct Snake
{
    private ushort[cells] segments;
    private size_t length;
    private ushort food;
    private Direction direction;
    private Direction nextDirection;
    private bool turnQueued;
    private Phase phase;
    private ulong lastStep;
    private uint random = 1;

    nothrow @nogc:

    void keyPress(Key key, ulong now)
    {
        if (key == Key.enter || key == ' ')
        {
            toggle(now);
            return;
        }

        if (phase != Phase.playing || turnQueued)
            return;
        Direction wanted;
        switch (key)
        {
            case Key.up: wanted = Direction.up; break;
            case Key.down: wanted = Direction.down; break;
            case Key.left: wanted = Direction.left; break;
            case Key.right: wanted = Direction.right; break;
            default: return;
        }
        if ((cast(uint) wanted + 2) % 4 != cast(uint) direction && wanted != direction)
        {
            nextDirection = wanted;
            turnQueued = true;
        }
    }

    void click(Rect body, int x, int y, ulong now)
    {
        if (control(body).contains(x, y))
            toggle(now);
    }

    /// 画面の手前から外れたゲームは一時停止し、復帰はプレイヤーが選ぶ。
    bool advance(ulong now, bool hasFocus)
    {
        if (phase != Phase.playing)
            return false;
        if (!hasFocus)
        {
            phase = Phase.paused;
            return true;
        }
        if (now - lastStep < stepTicks)
            return false;

        lastStep = now;
        step();
        return true;
    }

    private void toggle(ulong now)
    {
        if (phase == Phase.playing)
        {
            phase = Phase.paused;
            return;
        }
        if (phase == Phase.paused)
        {
            phase = Phase.playing;
            lastStep = now;
            return;
        }

        initializeBoard();
        random = cast(uint) now | 1;
        phase = Phase.playing;
        lastStep = now;
    }

    private void initializeBoard()
    {
        length = initialLength;
        foreach (i; 0 .. initialLength)
            segments[i] = cast(ushort) (rows / 2 * columns + 5 - i);
        food = rows / 2 * columns + 7;
        direction = Direction.right;
        nextDirection = direction;
        turnQueued = false;
    }

    private void step()
    {
        direction = nextDirection;
        turnQueued = false;

        int x = segments[0] % columns;
        int y = segments[0] / columns;
        final switch (direction)
        {
            case Direction.right: ++x; break;
            case Direction.down: ++y; break;
            case Direction.left: --x; break;
            case Direction.up: --y; break;
        }
        if (x < 0 || x >= columns || y < 0 || y >= rows)
        {
            phase = Phase.lost;
            return;
        }

        const next = cast(ushort) (y * columns + x);
        const grows = next == food;
        // 食べない回は尾が先へ動くため、現在の尾のマスへ進んでも衝突しない。
        foreach (cell; segments[0 .. (grows ? length : length - 1)])
            if (cell == next)
            {
                phase = Phase.lost;
                return;
            }

        if (grows)
            ++length;
        for (size_t i = length - 1; i > 0; --i)
            segments[i] = segments[i - 1];
        segments[0] = next;

        if (grows)
        {
            if (length == cells)
                phase = Phase.won;
            else
                placeFood();
        }
    }

    private void placeFood()
    {
        bool[cells] occupied;
        foreach (cell; segments[0 .. length])
            occupied[cell] = true;

        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        auto freeIndex = random % (cells - length);
        foreach (cell, used; occupied)
        {
            if (used)
                continue;
            if (freeIndex == 0)
            {
                food = cast(ushort) cell;
                return;
            }
            --freeIndex;
        }
    }

    void draw(ref Screen screen, Rect body) const
    {
        screen.fill(body, toolbar);
        screen.text(body.x + 13, body.y + 16, "Snake", ink, 2);
        screen.text(body.x + 128, body.y + 19, "Score", muted);
        char[20] digits = void;
        screen.text(body.x + 176, body.y + 19,
            decimalText(length > initialLength ? length - initialLength : 0, digits), ink);
        button(screen, control(body), controlLabel());

        const board = Rect(body.x + 16, body.y + 44, columns * cellSize, rows * cellSize);
        screen.fill(board, 0x233b4b);
        foreach (y; 0 .. rows)
            foreach (x; 0 .. columns)
                screen.fill(Rect(board.x + x * cellSize + 1, board.y + y * cellSize + 1,
                    cellSize - 1, cellSize - 1), ((x + y) % 2) ? 0x192f3d : 0x1b3443);
        if (phase != Phase.idle)
        {
            foreach (i, cell; segments[0 .. length])
                screen.fill(boardCell(board, cell), i ? 0x61b59f : 0xaeebce);
            if (phase != Phase.won)
                screen.fill(boardCell(board, food), 0xf1bc67);
        }

        if (phase != Phase.playing)
        {
            const status = Rect(board.x + 50, board.y + 78, board.width - 100, 38);
            screen.fill(status, ink);
            centeredText(screen, status, phaseText(), paper);
        }
        screen.text(body.x + 16, body.y + body.height - 18, "Arrows Move    Space Pause / resume", muted);
    }

    private Rect control(Rect body) const
    {
        return Rect(body.x + body.width - 84, body.y + 10, 68, 25);
    }

    private const(char)[] controlLabel() const
    {
        final switch (phase)
        {
            case Phase.idle: return "Start";
            case Phase.playing: return "Pause";
            case Phase.paused: return "Resume";
            case Phase.lost, Phase.won: return "Restart";
        }
    }

    private const(char)[] phaseText() const
    {
        final switch (phase)
        {
            case Phase.idle: return "Enter to start";
            case Phase.playing: return "";
            case Phase.paused: return "Paused";
            case Phase.lost: return "Game over";
            case Phase.won: return "Board cleared";
        }
    }
}

private Rect boardCell(Rect board, ushort cell) pure nothrow @nogc
{
    return Rect(board.x + cell % columns * cellSize + 2,
        board.y + cell / columns * cellSize + 2, cellSize - 3, cellSize - 3);
}
