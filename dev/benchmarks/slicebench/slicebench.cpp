#include <cstdio>
#include <vector>
int main() {
    long n = 200000, w = 32;
    std::vector<long> s(n);
    for (long i = 0; i < n; i++) s[i] = (i * 48271L) % 251L;
    long sum = 0;
    for (long r = 0; r < 8; r++)
        for (long j = 0; j < n - w; j++) {
            std::vector<long> t(s.begin() + j, s.begin() + j + w);
            sum += t[0] + t[w - 1];
        }
    printf("%ld\n", sum);
    return 0;
}
