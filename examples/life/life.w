// LIFE: Conway's Game of Life, drawn in ASCII, in word.
//
// A universe on a grid: each cell is alive (#) or dead. Every generation, all
// cells update at once by four rules that haven't changed since 1970:
//
//   - a live cell with 2 or 3 live neighbours survives
//   - a live cell with fewer than 2, or more than 3, dies
//   - a dead cell with exactly 3 live neighbours is born
//   - everything else stays dead
//
// The grid is a torus (the left edge neighbours the right, and the top the
// bottom), so a glider sails off one side and comes back on the other instead
// of dying at a wall.
//
// It's a small program that uses a lot of what word makes easy:
//
//   - a 2-D grid stored as one flat region, indexed by row*width + col
//   - double buffering: read the whole grid, write the next one, then swap
//   - regions built up character by character into each rendered row
//   - integers doing all the counting and the wrap-around arithmetic
//     ( (i + n) % n )
//
// It animates in place with ANSI escapes, so each generation is drawn over the
// last one and the grid moves instead of scrolling. `--plain` prints every
// generation in turn instead, which is what you want when piping the output
// somewhere or when your terminal doesn't understand the escapes.
//
// Run it with a starting pattern and a number of generations (at most 200):
//
//   word run life.w                 (glider, 60 generations)
//   word run life.w blinker 6
//   word run life.w pulsar 9
//   word run life.w glider 3 --plain
//
// Patterns: block  blinker  toad  beacon  glider  pulsar

// ------------------------------------------------------------
// A tiny integer parser for the generation-count argument, since
// args() hands back text, not a number.
// ------------------------------------------------------------

parse_int(s)
    n = 0
    seen = 0
    i = 0
    loop i < len(s)
        c = s[i]
        if c >= 48 && c <= 57
            n = n * 10 + (c - 48)
            seen = 1
            i = i + 1
        else
            return 0 - 1
    if seen == 0
        return 0 - 1
    return n

// ------------------------------------------------------------
// Grid helpers. The grid is a flat region of width*height cells,
// each 0 (dead) or 1 (alive); cell (r, c) lives at r*width + c.
// ------------------------------------------------------------

new_grid(size)
    g = text(size)
    i = 0
    loop i < size
        g[i] = 0
        i = i + 1
    return g

set_cell(g, w, r, c)
    g[r * w + c] = 1

// Count the eight neighbours of (r, c), wrapping around the torus. Adding w or
// h before the % keeps the operand non-negative, so the wrap is well defined.
neighbours(g, w, h, r, c)
    total = 0
    dr = 0 - 1
    loop dr <= 1
        dc = 0 - 1
        loop dc <= 1
            if dr != 0 || dc != 0
                rr = (r + dr + h) % h
                cc = (c + dc + w) % w
                total = total + g[rr * w + cc]
            dc = dc + 1
        dr = dr + 1
    return total

// Compute the next generation from `g` into `next` (the double buffer).
step(g, next, w, h)
    r = 0
    loop r < h
        c = 0
        loop c < w
            live = neighbours(g, w, h, r, c)
            here = g[r * w + c]
            born = 0
            if here == 1
                if live == 2 || live == 3
                    born = 1
            else
                if live == 3
                    born = 1
            next[r * w + c] = born
            c = c + 1
        r = r + 1

population(g, size)
    p = 0
    i = 0
    loop i < size
        p = p + g[i]
        i = i + 1
    return p

// ------------------------------------------------------------
// Rendering: build a border once, then each row as a string.
//
// The animation uses four ANSI escapes. ESC[2J clears the screen once at the
// start, ESC[H puts the cursor back at the top-left, ESC[K clears the rest of a
// line, and ESC[J clears whatever is left below the frame, so each frame is
// drawn straight over the last one. Two details of the language shape how
// they're written. There's no \x escape (SPEC 2.8), so the escape byte comes
// from char(27). And out() renders a word-backed region holding a control
// character as a list of numbers (SPEC 9.1), so the finished frame goes through
// encode(), whose byte-backed result out() writes as it is. The whole frame is
// built as one region and printed with one out(), which also keeps it from
// flickering.
// ------------------------------------------------------------

esc(tail)
    return char(27) . tail

// Spin until `ms` milliseconds have passed. now() is the only clock and there's
// no sleep, so a frame delay is a busy wait. That's fine for a demo of a few
// seconds, and it's the one part of the program that costs any real CPU.
wait_ms(ms)
    stop = now() + ms * 1000000
    left = 1
    loop left > 0
        left = stop - now()

make_border(w)
    line = "+"
    i = 0
    loop i < w
        line = line . "-"
        i = i + 1
    return line . "+"

// One frame, built whole and printed once. Animating, it starts at the home
// position and carries the banner with it, so every line on screen is redrawn
// from a known place; plain, it is the same text with a blank line in front.
render(g, w, h, gen, border, banner, live)
    eol = "\n"
    frame = "\n"
    if live != 0
        eol = esc("[K") . "\n"
        frame = esc("[H") . banner . "\n"
    frame = frame . "generation " . gen . "    population " . population(g, w * h) . eol
    frame = frame . border . eol
    r = 0
    loop r < h
        row = "|"
        c = 0
        loop c < w
            if g[r * w + c] == 1
                row = row . "#"
            else
                row = row . " "
            c = c + 1
        frame = frame . row . "|" . eol
        r = r + 1
    frame = frame . border
    if live != 0
        frame = frame . esc("[K") . esc("[J")
    out(encode(frame))

// ------------------------------------------------------------
// Starting patterns, placed near the middle of the grid. Returns 1
// if the name was known, 0 otherwise.
// ------------------------------------------------------------

seed(g, w, h, name)
    r = (h >> 1) - 2
    c = (w >> 1) - 2

    if name == "block"
        set_cell(g, w, r, c)
        set_cell(g, w, r, c + 1)
        set_cell(g, w, r + 1, c)
        set_cell(g, w, r + 1, c + 1)
        return 1

    if name == "blinker"
        set_cell(g, w, r, c)
        set_cell(g, w, r, c + 1)
        set_cell(g, w, r, c + 2)
        return 1

    if name == "toad"
        set_cell(g, w, r, c + 1)
        set_cell(g, w, r, c + 2)
        set_cell(g, w, r, c + 3)
        set_cell(g, w, r + 1, c)
        set_cell(g, w, r + 1, c + 1)
        set_cell(g, w, r + 1, c + 2)
        return 1

    if name == "beacon"
        set_cell(g, w, r, c)
        set_cell(g, w, r, c + 1)
        set_cell(g, w, r + 1, c)
        set_cell(g, w, r + 1, c + 1)
        set_cell(g, w, r + 2, c + 2)
        set_cell(g, w, r + 2, c + 3)
        set_cell(g, w, r + 3, c + 2)
        set_cell(g, w, r + 3, c + 3)
        return 1

    if name == "glider"
        set_cell(g, w, r, c + 1)
        set_cell(g, w, r + 1, c + 2)
        set_cell(g, w, r + 2, c)
        set_cell(g, w, r + 2, c + 1)
        set_cell(g, w, r + 2, c + 2)
        return 1

    if name == "pulsar"
        seed_pulsar(g, w, r + 2, c + 2)
        return 1

    return 0

// The pulsar: the classic 48-cell period-3 oscillator. It is four identical
// quadrants around an empty centre; `pulsar_arm` places one quadrant given the
// row/column signs (sr, sc), so the four calls build the whole figure. Each
// quadrant is two horizontal 3-bars (at row offsets 1 and 6) and two vertical
// 3-bars (at column offsets 1 and 6).
pulsar_arm(g, w, cr, cc, sr, sc)
    set_cell(g, w, cr + sr * 1, cc + sc * 2)
    set_cell(g, w, cr + sr * 1, cc + sc * 3)
    set_cell(g, w, cr + sr * 1, cc + sc * 4)
    set_cell(g, w, cr + sr * 6, cc + sc * 2)
    set_cell(g, w, cr + sr * 6, cc + sc * 3)
    set_cell(g, w, cr + sr * 6, cc + sc * 4)
    set_cell(g, w, cr + sr * 2, cc + sc * 1)
    set_cell(g, w, cr + sr * 3, cc + sc * 1)
    set_cell(g, w, cr + sr * 4, cc + sc * 1)
    set_cell(g, w, cr + sr * 2, cc + sc * 6)
    set_cell(g, w, cr + sr * 3, cc + sc * 6)
    set_cell(g, w, cr + sr * 4, cc + sc * 6)

seed_pulsar(g, w, cr, cc)
    pulsar_arm(g, w, cr, cc, 0 - 1, 0 - 1)
    pulsar_arm(g, w, cr, cc, 0 - 1, 1)
    pulsar_arm(g, w, cr, cc, 1, 0 - 1)
    pulsar_arm(g, w, cr, cc, 1, 1)

// ------------------------------------------------------------
// Main
// ------------------------------------------------------------

width = 28
height = 16
size = width * height

// The arguments are the pattern, then the generation count, with --plain
// anywhere among them to print every generation instead of animating in place.
a = args()
pattern = "glider"
gens = 0 - 1
live = 1
seen = 0
i = 1
loop i < len(a)
    arg = a[i]
    if arg == "--plain"
        live = 0
    else
        seen = seen + 1
        if seen == 1
            pattern = arg
        if seen == 2
            gens = parse_int(arg)
    i = i + 1

if gens < 0
    gens = 60
if gens > 200
    gens = 200

grid = new_grid(size)

if seed(grid, width, height, pattern) == 0
    out("Unknown pattern '" . pattern . "'.")
    out("Try one of: block blinker toad beacon glider pulsar")
    return 1

banner = "======================================\n"
banner = banner . "     C O N W A Y ' S   L I F E         \n"
banner = banner . "======================================\n"
banner = banner . "Pattern: " . pattern . "    " . gens . " generations on a " . width . "x" . height . " torus."

if live != 0
    out(encode(esc("[2J")))
else
    out(banner)

border = make_border(width)
buffer = new_grid(size)

render(grid, width, height, 0, border, banner, live)

gen = 1
loop gen <= gens
    if live != 0
        wait_ms(90)
    step(grid, buffer, width, height)
    swap = grid
    grid = buffer
    buffer = swap
    render(grid, width, height, gen, border, banner, live)
    gen = gen + 1

out("")
out("Still life, or forever in motion. That is all there is.")
