const n = 500000;
const m = new Map();
for (let i = 0; i < n; i++) m.set("k" + i, i);
let sum = 0;
for (let j = 0; j < n; j++) sum += m.get("k" + j);
console.log(m.size + " " + sum);
