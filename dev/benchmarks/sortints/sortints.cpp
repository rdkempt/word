#include <cstdio>
#include <vector>
#include <algorithm>
int main() {
    long n = 50000;
    std::vector<long> a(n);
    long x = 12345;
    for (long i = 0; i < n; i++) { x = (x * 48271) % 2147483647L; a[i] = x; }
    std::sort(a.begin(), a.end());
    long sum = 0;
    for (long v : a) sum += v;
    std::printf("%ld %ld %ld %ld\n", a[0], a[n / 2], a[n - 1], sum);
    return 0;
}
