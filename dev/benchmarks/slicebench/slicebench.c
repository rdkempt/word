/* Same shape as slicebench.w: an owned copy of each window, read and dropped.
   word's copy() allocates a new region (SPEC 3.4), so the comparison languages
   allocate too. A borrowed view would be measuring a different operation. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    long n = 200000, w = 32;
    long *s = malloc(n * sizeof(long));
    for (long i = 0; i < n; i++) s[i] = (i * 48271L) % 251L;
    long sum = 0;
    for (long r = 0; r < 8; r++)
        for (long j = 0; j < n - w; j++) {
            long *t = malloc(w * sizeof(long));
            memcpy(t, s + j, w * sizeof(long));
            sum += t[0] + t[w - 1];
            free(t);
        }
    printf("%ld\n", sum);
    return 0;
}
