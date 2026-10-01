#include <stdio.h>
static double dist(double x, double y) { return x * x + y * y; }
int main(void) {
    const int n = 3000000;
    long c = 0;
    for (int i = 0; i < n; i++) {
        double a = i * 0.5;
        double b = a + 1.5;
        if (dist(a, b) > 1000000.0) c++;
    }
    printf("%ld\n", c);
    return 0;
}
