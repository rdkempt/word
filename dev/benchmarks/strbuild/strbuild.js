const n = 200000;
const parts = [];
for (let i = 0; i < n; i++) parts.push("ab");
const s = parts.join("");
let sum = 0;
for (let j = 0; j < s.length; j++) sum += s.charCodeAt(j);
console.log(s.length + " " + sum);
