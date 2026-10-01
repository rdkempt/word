#include <stdio.h>
int main(void) {
    const int w = 200, h = 200, maxit = 500;
    long total = 0;
    for (int py = 0; py < h; py++) {
        for (int px = 0; px < w; px++) {
            double x0 = px * 3.5 / w - 2.5;
            double y0 = py * 2.0 / h - 1.0;
            double x = 0.0, y = 0.0;
            int it = 0;
            for (; it < maxit; it++) {
                double xx = x * x, yy = y * y;
                if (xx + yy > 4.0) break;
                y = 2.0 * x * y + y0;
                x = xx - yy + x0;
            }
            if (it == maxit) total++;
        }
    }
    printf("%ld\n", total);
    return 0;
}
