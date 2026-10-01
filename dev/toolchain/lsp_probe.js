#!/usr/bin/env node
// lsp_probe.js: drive editors/vscode/server.js over real LSP framing and check
// what comes back. test_langserver.sh runs it, and it can be run by hand.
//
// It speaks the wire protocol instead of calling the server's functions,
// because the framing is the part most likely to be slightly wrong (byte
// lengths against character lengths, partial reads), and a unit test would
// never see it.
//
//   node dev/toolchain/lsp_probe.js /path/to/word
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const wordBin = process.argv[2];
const root = path.resolve(__dirname, '..', '..');
const server = path.join(root, 'editors', 'vscode', 'server.js');

let failures = 0, checks = 0;
function ok(cond, what, detail) {
  checks++;
  if (cond) { console.log(`  ok: ${what}`); return true; }
  failures++;
  console.log(`  FAIL: ${what}`);
  if (detail !== undefined) console.log(`        ${typeof detail === 'string' ? detail : JSON.stringify(detail)}`);
  return false;
}

// ------------------------------------------------------------- a workspace
const ws = fs.mkdtempSync(path.join(os.tmpdir(), 'word-lsp-probe-'));
const appPath = path.join(ws, 'app.w');
const helperPath = path.join(ws, 'helper.w');

// HELPER has a non-ASCII comment: the framing counts bytes, and a server that
// counts characters cuts the message short there and never recovers.
const APP = [
  'total = 0',
  'i = 0',
  'loop i < 3',
  '    total = total + twice(i)',
  '    i = i + 1',
  'out(total)',
  ''
].join('\n');

const HELPER = [
  '// Double a number. Café — a non-ASCII comment, to exercise the byte framing.',
  'twice(n)',
  '    return n * 2',
  '',
  'twice:before',
  '    if n < 0',
  '        return false',
  '    return true',
  ''
].join('\n');

fs.writeFileSync(appPath, APP);
fs.writeFileSync(helperPath, HELPER);

// ------------------------------------------------------------- the client
const proc = spawn(process.execPath, [server, '--word', wordBin, '--stdio'],
                   { stdio: ['pipe', 'pipe', 'inherit'] });
let buf = Buffer.alloc(0);
const pending = new Map();       // id -> resolve
const notes = [];                // every notification the server sent
const noteWaiters = [];

proc.stdout.on('data', (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const split = buf.indexOf('\r\n\r\n');
    if (split < 0) return;
    const m = /Content-Length:\s*(\d+)/i.exec(buf.slice(0, split).toString('ascii'));
    if (!m) { buf = buf.slice(split + 4); continue; }
    const len = parseInt(m[1], 10);
    if (buf.length < split + 4 + len) return;
    const msg = JSON.parse(buf.slice(split + 4, split + 4 + len).toString('utf8'));
    buf = buf.slice(split + 4 + len);
    if (msg.id !== undefined && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    else { notes.push(msg); for (const w of noteWaiters.splice(0)) w(); }
  }
});

let nextId = 1;
function send(obj) {
  const body = Buffer.from(JSON.stringify(Object.assign({ jsonrpc: '2.0' }, obj)), 'utf8');
  proc.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  proc.stdin.write(body);
}
function request(method, params) {
  const id = nextId++;
  return new Promise((res) => { pending.set(id, res); send({ id, method, params }); });
}
function notify(method, params) { send({ method, params }); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Wait for a diagnostics publish for `uri`, after `since`, that satisfies
// `want`. It's a predicate instead of "the next one" because an edit to one
// file republishes the whole program, so the newest publish for a URI may come
// from another file's debounce, built from the text before the edit. Waiting
// for the answer we're asking about removes that race without weakening the
// check: a server that never produces it still times out, and the check fails
// with whatever it did produce.
async function diagnosticsFor(uri, since, want, timeoutMs) {
  const deadline = Date.now() + (timeoutMs || 8000);
  let last = null;
  for (;;) {
    for (let i = since; i < notes.length; i++) {
      const n = notes[i];
      if (n.method !== 'textDocument/publishDiagnostics' || n.params.uri !== uri) continue;
      last = n.params.diagnostics;
      if (!want || want(last)) return last;
    }
    if (Date.now() > deadline) return last;
    await new Promise((r) => { noteWaiters.push(r); setTimeout(r, 40); });
  }
}
const noErrors = (d) => d.length === 0;
const says = (re) => (d) => d.length === 1 && re.test(d[0].message);
const uriOf = (p) => {
  let abs = path.resolve(p).replace(/\\/g, '/');
  if (!abs.startsWith('/')) abs = '/' + abs;
  return 'file://' + abs.split('/').map(encodeURIComponent).join('/').replace(/%3A/gi, ':');
};
const appUri = uriOf(appPath), helperUri = uriOf(helperPath);

(async function main() {
  // ---------------------------------------------------------- initialize
  // The workspace root is the repo, not the scratch folder: that's what a
  // checkout looks like, and it's where `./word` lives.
  const init = await request('initialize', {
    processId: process.pid, rootUri: uriOf(root), capabilities: {},
    initializationOptions: { wordPath: wordBin }
  });
  const caps = init.result && init.result.capabilities;
  ok(!!caps, 'initialize answers with capabilities');
  for (const c of ['definitionProvider', 'hoverProvider', 'documentSymbolProvider',
                   'documentFormattingProvider', 'renameProvider', 'completionProvider',
                   'referencesProvider']) {
    ok(caps && caps[c], `advertises ${c}`);
  }
  notify('initialized', {});

  // ------------------------------------------------ diagnostics: the buffer
  let since = notes.length;
  notify('textDocument/didOpen', { textDocument: { uri: appUri, languageId: 'word', version: 1, text: APP } });
  notify('textDocument/didOpen', { textDocument: { uri: helperUri, languageId: 'word', version: 1, text: HELPER } });
  let d = await diagnosticsFor(appUri, since, noErrors);
  ok(d && d.length === 0, 'a correct program produces no diagnostics', d);

  // An error typed into the buffer, never written to disk. If the server built
  // the file on disk instead of the buffer, this reports nothing.
  since = notes.length;
  const broken = APP.replace('out(total)', 'out(totl)');
  notify('textDocument/didChange', { textDocument: { uri: appUri, version: 2 }, contentChanges: [{ text: broken }] });
  d = await diagnosticsFor(appUri, since, says(/totl/));
  ok(d && d.length === 1, 'an unsaved edit is what gets compiled', d);
  ok(d && d[0] && /undefined variable 'totl'/.test(d[0].message), 'the diagnostic is the compiler\'s own words', d && d[0]);
  ok(d && d[0] && d[0].range.start.line === 5 && d[0].range.start.character === 4,
     'the diagnostic lands on the identifier, zero-based', d && d[0] && d[0].range);
  ok(d && d[0] && d[0].range.end.character === 8,
     'the range covers the whole identifier, not one character', d && d[0] && d[0].range);
  ok(fs.readFileSync(appPath, 'utf8') === APP, 'the file on disk was not touched');

  // Fixing it clears the diagnostic.
  since = notes.length;
  notify('textDocument/didChange', { textDocument: { uri: appUri, version: 3 }, contentChanges: [{ text: APP }] });
  d = await diagnosticsFor(appUri, since, noErrors);
  ok(d && d.length === 0, 'fixing the buffer clears the diagnostic', d);

  // An error in a sibling is reported against the sibling, not the entry file.
  since = notes.length;
  const brokenHelper = HELPER.replace('return n * 2', 'return n * zz');
  notify('textDocument/didChange', { textDocument: { uri: helperUri, version: 2 }, contentChanges: [{ text: brokenHelper }] });
  const dh = await diagnosticsFor(helperUri, since, says(/zz/));
  ok(dh && dh.length === 1 && /undefined variable 'zz'/.test(dh[0].message),
     'an error in a sibling file is attributed to that file', dh);
  ok(dh && dh[0] && dh[0].range.start.line === 2,
     'attributed to the sibling\'s own line number', dh && dh[0] && dh[0].range);
  since = notes.length;
  notify('textDocument/didChange', { textDocument: { uri: helperUri, version: 3 }, contentChanges: [{ text: HELPER }] });
  ok((await diagnosticsFor(helperUri, since, noErrors) || []).length === 0, 'the sibling clears too');

  // ---------------------------------------------------------- definition
  // `twice` on app.w:4 is defined in helper.w, because the folder is the program.
  let r = await request('textDocument/definition', {
    textDocument: { uri: appUri }, position: { line: 3, character: 24 } });
  ok(r.result && r.result.uri === helperUri && r.result.range.start.line === 1,
     'go to definition crosses to the sibling that defines it', r.result);

  // `total` is a local of the top level; its definition is where it was bound.
  r = await request('textDocument/definition', {
    textDocument: { uri: appUri }, position: { line: 3, character: 6 } });
  ok(r.result && r.result.uri === appUri && r.result.range.start.line === 0,
     'go to definition on a local finds its binding', r.result);

  // A parameter resolves inside its own function, not to something in app.w.
  r = await request('textDocument/definition', {
    textDocument: { uri: helperUri }, position: { line: 2, character: 11 } });
  ok(r.result && r.result.uri === helperUri && r.result.range.start.line === 1,
     'go to definition on a parameter lands on the header', r.result);

  // --------------------------------------------------------------- hover
  r = await request('textDocument/hover', { textDocument: { uri: appUri }, position: { line: 5, character: 1 } });
  ok(r.result && /Builtin \(SPEC §9\)/.test(r.result.contents.value) && /out\(x\)/.test(r.result.contents.value),
     'hover on a builtin gives its signature and the SPEC section', r.result && r.result.contents.value);

  r = await request('textDocument/hover', { textDocument: { uri: appUri }, position: { line: 3, character: 24 } });
  ok(r.result && /twice\(n\)/.test(r.result.contents.value) && /Double a number/.test(r.result.contents.value),
     'hover on a user function gives its signature and its comment', r.result && r.result.contents.value);
  ok(r.result && /:before/.test(r.result.contents.value),
     'hover says the function is guarded by a contract', r.result && r.result.contents.value);

  r = await request('textDocument/hover', { textDocument: { uri: helperUri }, position: { line: 2, character: 11 } });
  ok(r.result && /Parameter of/.test(r.result.contents.value), 'hover on a parameter says so', r.result && r.result.contents.value);

  // ------------------------------------------------------------- symbols
  r = await request('textDocument/documentSymbol', { textDocument: { uri: helperUri } });
  const names = (r.result || []).map((s) => s.name);
  ok(names.includes('twice(n)'), 'the outline lists the function with its parameters', names);
  ok(names.includes('twice:before'), 'the outline lists the contract hook', names);

  // ---------------------------------------------------------- formatting
  const ugly = 'f(a)\n  return a\n\nout(f(1))\n';
  const uglyPath = path.join(ws, 'ugly.w');
  const uglyUri = uriOf(uglyPath);
  fs.writeFileSync(uglyPath, ugly);
  notify('textDocument/didOpen', { textDocument: { uri: uglyUri, languageId: 'word', version: 1, text: ugly } });
  r = await request('textDocument/formatting', { textDocument: { uri: uglyUri }, options: { tabSize: 4, insertSpaces: true } });
  ok(r.result && r.result.length === 1 && /\n    return a/.test(r.result[0].newText),
     'formatting returns word format\'s own four-space layout', r.result);
  ok(fs.readFileSync(uglyPath, 'utf8') === ugly, 'formatting did not rewrite the file behind the editor\'s back');

  // ---------------------------------------------------------- completion
  r = await request('textDocument/completion', { textDocument: { uri: appUri }, position: { line: 5, character: 4 } });
  const labels = (r.result || []).map((c) => c.label);
  ok(labels.includes('out') && labels.includes('len'), 'completion offers builtins', labels.slice(0, 10));
  ok(labels.includes('twice'), 'completion offers functions from the sibling file');
  ok(labels.includes('total') && labels.includes('i'), 'completion offers locals in scope');
  ok(labels.includes('read') && labels.includes('split'), 'completion offers module functions, which need no import');
  ok(!labels.includes('asmput'), 'completion does not offer sys, which is documented for honesty not use');
  ok(labels.includes('true') && labels.includes('none'), 'completion offers the singletons');

  // `import ` takes one of a closed list and nothing else.
  const imp = 'import f\n' + APP;
  const impUri = uriOf(path.join(ws, 'imp.w'));
  notify('textDocument/didOpen', { textDocument: { uri: impUri, languageId: 'word', version: 1, text: imp } });
  r = await request('textDocument/completion', { textDocument: { uri: impUri }, position: { line: 0, character: 8 } });
  const impLabels = (r.result || []).map((c) => c.label).sort();
  ok(JSON.stringify(impLabels) === JSON.stringify(['fs', 'json', 'net', 'sys', 'txt']),
     'after `import` the offer is exactly the closed module list', impLabels);

  // Inside a kind test the answer set is closed too.
  const kindSrc = 'x = in()\nif kind(x) == "n\n    out(1)\n';
  const kindUri = uriOf(path.join(ws, 'kind.w'));
  notify('textDocument/didOpen', { textDocument: { uri: kindUri, languageId: 'word', version: 1, text: kindSrc } });
  r = await request('textDocument/completion', { textDocument: { uri: kindUri }, position: { line: 1, character: 16 } });
  const kindLabels = (r.result || []).map((c) => c.label);
  ok(kindLabels.includes('number') && kindLabels.includes('bytes') && !kindLabels.includes('out'),
     'inside a kind test the offer is the names kind() can answer', kindLabels);

  // -------------------------------------------------------------- rename
  r = await request('textDocument/prepareRename', { textDocument: { uri: appUri }, position: { line: 5, character: 1 } });
  ok(r.error && /builtin/.test(r.error.message), 'renaming a builtin is refused, with a reason', r.error || r.result);

  r = await request('textDocument/rename', {
    textDocument: { uri: helperUri }, position: { line: 1, character: 0 }, newName: 'doubled' });
  const changes = r.result && r.result.changes;
  ok(!!changes, 'renaming a function returns an edit', r.error || r.result);
  const helperEdits = changes ? (changes[helperUri] || []) : [];
  const appEdits = changes ? (changes[appUri] || []) : [];
  ok(helperEdits.length === 2, 'the definition and its hook header are both renamed', helperEdits);
  ok(appEdits.length === 1 && appEdits[0].range.start.line === 3,
     'the call site in the other file is renamed too', appEdits);

  r = await request('textDocument/rename', {
    textDocument: { uri: helperUri }, position: { line: 2, character: 11 }, newName: 'v' });
  const localChanges = r.result && r.result.changes;
  ok(localChanges && !localChanges[appUri], 'renaming a parameter does not reach into another file', localChanges);
  const nLines = (localChanges ? localChanges[helperUri] || [] : []).map((e) => e.range.start.line).sort((a, b) => a - b);
  ok(JSON.stringify(nLines) === JSON.stringify([1, 2]),
     'renaming a parameter stays inside its own function, not the hook that also uses n', nLines);

  r = await request('textDocument/rename', {
    textDocument: { uri: helperUri }, position: { line: 1, character: 0 }, newName: 'len' });
  ok(r.error && /builtin/.test(r.error.message), 'renaming onto a builtin is refused', r.error || r.result);

  r = await request('textDocument/rename', {
    textDocument: { uri: helperUri }, position: { line: 1, character: 0 }, newName: '2bad' });
  ok(r.error && /identifier/.test(r.error.message), 'renaming to a non-identifier is refused', r.error || r.result);

  // ---------------------------------------------------------- references
  r = await request('textDocument/references', {
    textDocument: { uri: helperUri }, position: { line: 1, character: 0 }, context: { includeDeclaration: true } });
  ok(r.result && r.result.length === 3, 'references finds the definition, the hook and the call', r.result);

  // SPEC 2.5: builtins are ordinary identifiers a program may shadow, and when
  // it does, the program's definition wins. So a `len` the program wrote is the
  // program's to rename, and refusing it would contradict the language. (The
  // compiler agrees: this program prints 100.)
  const shadow = ['len(x)', '    return 99', '', 'result = 1', 'out(len("ab") + result)', ''].join('\n');
  const shadowPath = path.join(ws, 'shadow.w');
  const shadowUri = uriOf(shadowPath);
  fs.writeFileSync(shadowPath, shadow);
  notify('textDocument/didOpen', { textDocument: { uri: shadowUri, languageId: 'word', version: 1, text: shadow } });
  r = await request('textDocument/rename', {
    textDocument: { uri: shadowUri }, position: { line: 0, character: 1 }, newName: 'size' });
  ok(r.result && r.result.changes && (r.result.changes[shadowUri] || []).length === 2,
     'a builtin the program shadows is the program\'s own name, and renameable', r.error || r.result);

  // `result` is contextual: meaningful only inside an `:after` hook, an
  // ordinary identifier everywhere else (SPEC 2.4).
  r = await request('textDocument/rename', {
    textDocument: { uri: shadowUri }, position: { line: 3, character: 2 }, newName: 'total' });
  ok(r.result && r.result.changes && (r.result.changes[shadowUri] || []).length === 2,
     'a local named `result` outside an :after hook is an ordinary name', r.error || r.result);

  // Renaming onto a keyword is still refused, with the reason.
  r = await request('textDocument/rename', {
    textDocument: { uri: shadowUri }, position: { line: 3, character: 2 }, newName: 'if' });
  ok(r.error && /keyword/.test(r.error.message), 'renaming onto a keyword is refused', r.error || r.result);
  notify('textDocument/didClose', { textDocument: { uri: shadowUri } });

  // ------------------------------------------- the largest program there is
  // The whole toolchain in one file. A timeout, a truncated pipe or a mirror
  // that lost a file shows up here first. The size is counted, not typed: a
  // typed "28,000 lines" went stale here and was printed in CI's log for a
  // release and a half.
  const selfPath = path.join(root, 'compiler', 'word.w');
  const selfUri = uriOf(selfPath);
  const selfText = fs.readFileSync(selfPath, 'utf8');
  const selfLines = (selfText.split('\n').length - 1).toLocaleString('en-US');
  since = notes.length;
  notify('textDocument/didOpen', { textDocument: { uri: selfUri, languageId: 'word', version: 1, text: selfText } });
  const ds = await diagnosticsFor(selfUri, since, noErrors, 30000);
  ok(ds && ds.length === 0, `the compiler itself, all ${selfLines} lines of it, compiles clean through the server`, ds);

  since = notes.length;
  const selfBroken = selfText.replace('builtin_arity(name)\n', 'builtin_arity(name)\n    q = zzz\n');
  ok(selfBroken !== selfText, 'the probe could inject an error into the compiler source');
  notify('textDocument/didChange', { textDocument: { uri: selfUri, version: 2 }, contentChanges: [{ text: selfBroken }] });
  const ds2 = await diagnosticsFor(selfUri, since, says(/zzz/), 30000);
  ok(ds2 && ds2.length === 1 && /undefined variable 'zzz'/.test(ds2[0].message),
     `an error typed into it is found, from the buffer, at ${selfLines} lines`, ds2);
  ok(fs.readFileSync(selfPath, 'utf8') === selfText, 'and the compiler source on disk is untouched');
  notify('textDocument/didClose', { textDocument: { uri: selfUri } });

  // ------------------------------------------------------------ shutdown
  await request('shutdown', null);
  notify('exit', null);
  await sleep(150);
  try { proc.kill(); } catch (e) { /* already gone */ }
  fs.rmSync(ws, { recursive: true, force: true });

  console.log(`\nlsp_probe: ${checks - failures}/${checks} checks passed`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => {
  console.log('lsp_probe: threw ' + (e && e.stack || e));
  try { proc.kill(); } catch (e2) { /* already gone */ }
  process.exit(1);
});
