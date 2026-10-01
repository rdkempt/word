fn main() {
    let n: usize = 50000;
    let mut a = vec![0i64; n];
    let mut x: i64 = 12345;
    for i in 0..n {
        x = (x * 48271) % 2147483647;
        a[i] = x;
    }
    a.sort_unstable();
    let sum: i64 = a.iter().sum();
    println!("{} {} {} {}", a[0], a[n / 2], a[n - 1], sum);
}
