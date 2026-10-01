const w = 200, h = 200, maxit = 500;
let total = 0;
for (let py = 0; py < h; py++) {
  for (let px = 0; px < w; px++) {
    const x0 = px * 3.5 / w - 2.5;
    const y0 = py * 2.0 / h - 1.0;
    let x = 0.0, y = 0.0, it = 0;
    while (it < maxit) {
      const xx = x * x, yy = y * y;
      if (xx + yy > 4.0) break;
      y = 2.0 * x * y + y0;
      x = xx - yy + x0;
      it++;
    }
    if (it === maxit) total++;
  }
}
console.log(total);
