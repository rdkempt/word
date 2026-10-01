#include <cstdio>
#include <vector>
int main() {
    const long N = 10000000;
    std::vector<unsigned char> flags(N + 1, 0);
    long count = 0;
    for (long i = 2; i <= N; i++) {
        if (!flags[i]) {
            count++;
            for (long j = i * i; j <= N; j += i) flags[j] = 1;
        }
    }
    std::printf("%ld\n", count);
    return 0;
}
