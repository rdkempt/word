w = h = 200
maxit = 500
total = 0
for py in range(h):
    for px in range(w):
        x0 = px * 3.5 / w - 2.5
        y0 = py * 2.0 / h - 1.0
        x = y = 0.0
        it = 0
        while it < maxit:
            xx = x * x
            yy = y * y
            if xx + yy > 4.0:
                break
            y = 2.0 * x * y + y0
            x = xx - yy + x0
            it += 1
        if it == maxit:
            total += 1
print(total)
