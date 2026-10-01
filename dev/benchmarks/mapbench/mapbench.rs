use std::collections::HashMap;
fn main() {
    let n: i64 = 500000;
    let mut m: HashMap<String, i64> = HashMap::new();
    for i in 0..n { m.insert(format!("k{}", i), i); }
    let mut sum: i64 = 0;
    for j in 0..n { sum += m[&format!("k{}", j)]; }
    println!("{} {}", m.len(), sum);
}
