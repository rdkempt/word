const n = 200000, w = 32;
const s = new Array(n);
for (let i = 0; i < n; i++) s[i] = (i * 48271) % 251;
let sum = 0;
for (let r = 0; r < 8; r++) {
  for (let j = 0; j < n - w; j++) {
    const t = s.slice(j, j + w);
    sum += t[0] + t[w - 1];
  }
}
console.log(sum);
