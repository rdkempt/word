fn main() {
    let (w, h, maxit) = (200i32, 200i32, 500i32);
    let mut total: i64 = 0;
    for py in 0..h {
        for px in 0..w {
            let x0 = px as f64 * 3.5 / w as f64 - 2.5;
            let y0 = py as f64 * 2.0 / h as f64 - 1.0;
            let (mut x, mut y) = (0.0f64, 0.0f64);
            let mut it = 0;
            while it < maxit {
                let (xx, yy) = (x * x, y * y);
                if xx + yy > 4.0 { break; }
                y = 2.0 * x * y + y0;
                x = xx - yy + x0;
                it += 1;
            }
            if it == maxit { total += 1; }
        }
    }
    println!("{}", total);
}
