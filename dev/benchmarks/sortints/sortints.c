#include <stdio.h>
#include <stdlib.h>
static int cmp(const void *a, const void *b) {
    long x = *(const long *)a, y = *(const long *)b;
    return (x > y) - (x < y);
}
int main(void) {
    long n = 50000;
    long *a = malloc(n * sizeof(long));
    long x = 12345;
    for (long i = 0; i < n; i++) { x = (x * 48271) % 2147483647L; a[i] = x; }
    qsort(a, n, sizeof(long), cmp);
    long sum = 0;
    for (long j = 0; j < n; j++) sum += a[j];
    printf("%ld %ld %ld %ld\n", a[0], a[n / 2], a[n - 1], sum);
    return 0;
}
