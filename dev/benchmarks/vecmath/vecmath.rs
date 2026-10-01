fn dist(x: f64, y: f64) -> f64 { x * x + y * y }
fn main() {
    let n = 3_000_000i32;
    let mut c: i64 = 0;
    for i in 0..n {
        let a = i as f64 * 0.5;
        let b = a + 1.5;
        if dist(a, b) > 1000000.0 { c += 1; }
    }
    println!("{}", c);
}
