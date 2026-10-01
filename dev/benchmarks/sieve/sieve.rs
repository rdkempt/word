fn main() {
    const N: usize = 10_000_000;
    let mut flags = vec![0u8; N + 1];
    let mut count: i64 = 0;
    let mut i: usize = 2;
    while i <= N {
        if flags[i] == 0 {
            count += 1;
            let mut j = i * i;
            while j <= N {
                flags[j] = 1;
                j += i;
            }
        }
        i += 1;
    }
    println!("{}", count);
}
