fn main() {
    let n = 200000;
    let mut s = String::new();
    for i in 0..n {
        s.push('<');
        s.push_str(&i.to_string());
        s.push('>');
    }
    let sum: i64 = s.bytes().map(|b| b as i64).sum();
    println!("{} {}", s.len(), sum);
}
