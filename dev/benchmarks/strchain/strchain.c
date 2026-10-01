#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    long n = 200000, cap = 16, len = 0;
    char *s = malloc(cap);
    char num[24];
    for (long i = 0; i < n; i++) {
        int k = snprintf(num, sizeof num, "%ld", i);
        while (len + k + 2 > cap) { cap *= 2; s = realloc(s, cap); }
        s[len++] = '<';
        memcpy(s + len, num, k); len += k;
        s[len++] = '>';
    }
    long sum = 0;
    for (long j = 0; j < len; j++) sum += (unsigned char)s[j];
    printf("%ld %ld\n", len, sum);
    return 0;
}
