// Sieve of Eratosthenes to 10,000,000: array indexing and tight loops.
// bytes(n) is the packed 1-byte-per-element region (SPEC §9), so the flag
// array costs 10 MB instead of 80 MB.
n = 10000000
flags = bytes(n + 1)
count = 0
i = 2
loop i <= n
    if flags[i] == 0
        count = count + 1
        j = i * i
        loop j <= n
            flags[j] = 1
            j = j + i
    i = i + 1
out(count)
