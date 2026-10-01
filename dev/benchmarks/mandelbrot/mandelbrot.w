// Mandelbrot: count the points of a 200x200 grid that stay bounded for 500
// iterations. It's pure floating point, and a word float is a boxed IEEE-754
// double in the arena (SPEC §3.6; x86-64 keeps many results unboxed), so this
// benchmark is the hardest case for the value model.
w = 200
h = 200
maxit = 500
total = 0
py = 0
loop py < h
    px = 0
    loop px < w
        x0 = px * 3.5 / w - 2.5
        y0 = py * 2.0 / h - 1.0
        x = 0.0
        y = 0.0
        it = 0
        loop it < maxit
            xx = x * x
            yy = y * y
            if xx + yy > 4.0
                break
            y = 2.0 * x * y + y0
            x = xx - yy + x0
            it = it + 1
        if it == maxit
            total = total + 1
        px = px + 1
    py = py + 1
out(total)
