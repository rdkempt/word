#!/usr/bin/env node
// test_outline.js: the language server's scanner, checked against the
// compiler's own idea of what a function is.
//
// The server doesn't parse word. It reads a file line by line to answer "what
// is defined here" and "what's in scope", and that's the one place it can be
// wrong without the compiler catching it. So it's checked against something
// the compiler already emits: every function becomes an `fn_<name>:` label in
// `word build -asm` output, and the scanner's answer must be that set.
//
// The first run found two bugs, both from the same ambiguity: at column 0,
// `twice(n)` is a definition and `out(total)` is a call, and only the indented
// block under the line tells them apart.
//
//   node dev/toolchain/test_outline.js /path/to/word
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const wordBin = process.argv[2];
const root = path.resolve(__dirname, '..', '..');
const { scan, programOf } = require(path.join(root, 'editors', 'vscode', 'server.js'));

let failures = 0, checked = 0, functions = 0;
function fail(what, detail) {
  failures++;
  console.log(`  FAIL: ${what}`);
  if (detail) console.log(`        ${detail}`);
}

// Every .w file in the tree, minus anything generated or temporary.
function allW(dir, out) {
  out = out || [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === '.git' || e.name === 'node_modules') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) allW(p, out);
    else if (e.name.endsWith('.w')) out.push(p);
  }
  return out;
}

const namesOfText = (t) =>
  new Set(scan(t).funcs.filter((f) => f.name).map((f) => f.name));
const names = (file) => namesOfText(fs.readFileSync(file, 'utf8'));

// The `net` library's functions turn up in two places the oracle has to account
// for, and both come from the NETLIB region of compiler/word.w (see
// netlib_embed):
//   - a net program bundles them behind its entry file (SPEC 12.2), so they're
//     in that program's oracle without being in its own directory; and
//   - they're in the text of compiler/word.w, so the scanner reports them when
//     it reads that file, but the compiler strips the region before building
//     itself, so they aren't in compiler/word.w's oracle.
// Either way they're real, so hold their names aside for both checks below.
// Scanning the whole region gives the same set as the old per-file scan of
// runtime/crypto/*.w did.
const cryptoNames = new Set();
{
  const wsrc = fs.readFileSync(path.join(root, 'compiler', 'word.w'), 'utf8');
  const rb = wsrc.indexOf('// >>> NETLIB BEGIN');
  const re = wsrc.indexOf('// <<< NETLIB END <<<');
  if (rb >= 0 && re >= 0) for (const n of namesOfText(wsrc.slice(rb, re))) cryptoNames.add(n);
}

const files = allW(root).sort();
console.log(`  scanning ${files.length} .w files`);

for (const file of files) {
  // Only entry files have an oracle: a file the compiler won't build alone (a
  // bundled module, a definitions-only sibling) has no assembly to read.
  const r = spawnSync(wordBin, ['build', '-asm', file], { cwd: root, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 0) continue;

  const oracle = new Set();
  for (const m of String(r.stdout).matchAll(/^fn_([A-Za-z_][A-Za-z0-9_]*):$/gm)) {
    if (m[1] !== '_toplevel') oracle.add(m[1]);
  }
  if (oracle.size === 0) continue;

  const prog = programOf(file);
  const mine = new Set();
  for (const f of prog.files) { for (const n of names(f)) mine.add(n); }

  checked++;
  functions += oracle.size;
  const rel = path.relative(root, file);

  // Nothing the scanner reports may be something the compiler doesn't define.
  // This is the check that catches a call read as a definition. Names from the
  // NETLIB region are the exception (see cryptoNames): the scanner sees them in
  // compiler/word.w, but the compiler strips the region before building it, so
  // they're real definitions that are missing from the oracle for a reason.
  const invented = [...mine].filter((n) => !oracle.has(n) && !cryptoNames.has(n));
  if (invented.length) fail(`${rel}: the outline invented ${invented.length} name(s)`, invented.slice(0, 8).join(', '));

  // And nothing the compiler defines may be missing from the outline.
  const missed = [...oracle].filter((n) => !mine.has(n) && !cryptoNames.has(n));
  if (missed.length) fail(`${rel}: the outline missed ${missed.length} function(s)`, missed.slice(0, 8).join(', '));
}

if (checked === 0) { console.log('  FAIL: no file produced an oracle, so the check ran on nothing'); process.exit(1); }
// compiler/word.w alone has over 600 functions, and a scrape that found only a
// handful would pass every subset check above while checking almost nothing.
if (functions < 500) { console.log(`  FAIL: only ${functions} functions checked, expected the compiler's own 600+`); process.exit(1); }

if (failures === 0) console.log(`  ok: ${functions} function definitions across ${checked} program(s) match the compiler's labels`);
process.exit(failures === 0 ? 0 : 1);
