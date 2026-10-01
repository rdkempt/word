#include <cstdio>
#include <string>
#include <unordered_map>
int main() {
    const long n = 500000;
    std::unordered_map<std::string, long> m;
    for (long i = 0; i < n; i++) m["k" + std::to_string(i)] = i;
    long sum = 0;
    for (long j = 0; j < n; j++) sum += m["k" + std::to_string(j)];
    std::printf("%zu %ld\n", m.size(), sum);
    return 0;
}
