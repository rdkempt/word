#include <cstdio>
#include <string>
int main() {
    const long n = 200000;
    std::string s;
    for (long i = 0; i < n; i++) s += "<" + std::to_string(i) + ">";
    long sum = 0;
    for (char c : s) sum += (unsigned char)c;
    std::printf("%zu %ld\n", s.size(), sum);
    return 0;
}
