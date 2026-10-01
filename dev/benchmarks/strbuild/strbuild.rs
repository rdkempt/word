fn main() {
    let n = 200000;
    let mut s = String::new();
    for _ in 0..n { s.push_str("ab"); }
    let sum: i64 = s.bytes().map(|b| b as i64).sum();
    println!("{} {}", s.len(), sum);
}
