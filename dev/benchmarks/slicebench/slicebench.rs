fn main() {
    let n: i64 = 200000;
    let w: usize = 32;
    let mut s = vec![0i64; n as usize];
    for i in 0..n { s[i as usize] = (i * 48271) % 251; }
    let mut sum: i64 = 0;
    for _ in 0..8 {
        for j in 0..(n as usize - w) {
            let t = s[j..j + w].to_vec();
            sum += t[0] + t[w - 1];
        }
    }
    println!("{}", sum);
}
