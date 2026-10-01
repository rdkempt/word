const fs = require("fs");
let text;
try { text = fs.readFileSync("data.json", "utf8"); }
catch (e) { console.error("run gen.w first"); process.exit(1); }
const docs = JSON.parse(text);
let sum = 0, active = 0;
for (const rec of docs) { sum += rec.score; active += rec.active; }
const out = JSON.stringify(docs);
console.log(docs.length + " " + sum + " " + active + " " + out.length);
