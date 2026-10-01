const n = 50000;
const a = new Array(n);
let x = 12345;
for (let i = 0; i < n; i++) {
  x = (x * 48271) % 2147483647;
  a[i] = x;
}
a.sort((p, q) => p - q);
let sum = 0;
for (const v of a) sum += v;
console.log(a[0] + " " + a[n / 2] + " " + a[n - 1] + " " + sum);
