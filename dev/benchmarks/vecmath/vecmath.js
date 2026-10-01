function dist(x, y) { return x * x + y * y; }
const n = 3000000;
let c = 0;
for (let i = 0; i < n; i++) {
    const a = i * 0.5;
    const b = a + 1.5;
    if (dist(a, b) > 1000000.0) c++;
}
console.log(c);
