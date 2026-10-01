#include <stdio.h>
#include <stdlib.h>
#define N 10000000
int main(void) {
    unsigned char *flags = calloc(N + 1, 1);
    long count = 0;
    for (long i = 2; i <= N; i++) {
        if (!flags[i]) {
            count++;
            for (long j = i * i; j <= N; j += i) flags[j] = 1;
        }
    }
    printf("%ld\n", count);
    return 0;
}
