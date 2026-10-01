#!/usr/bin/env node
// server.js: a language server for word, over stdio, with no dependencies.
//
// The server never makes a judgement the compiler already makes. Diagnostics
// are `word build`'s own stderr, parsed. Formatting is `word format`'s own
// output. The builtin and module tables in langdata.json are generated from
// compiler/word.w and SPEC.md (dev/toolchain/gen_lspdata.sh). The code here
// covers only what the compiler has no reason to expose: where a name is
// defined, what's in scope at a point, and how to rename one.
//
// A language server with its own parser drifts away from the compiler and
// starts underlining correct code, and that's when people turn the extension
// off. The scanner here can get an outline wrong, but every error comes from
// the compiler.
//
// Usage:  node server.js [--word <path to the word binary>] [--stdio]
// `--stdio` is accepted and ignored, since most editors pass it.

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const DATA = JSON.parse(fs.readFileSync(path.join(__dirname, 'langdata.json'), 'utf8'));

// ---------------------------------------------------------------- transport
// LSP framing: `Content-Length: n\r\n\r\n` and then n bytes of UTF-8 JSON. The
// length counts bytes, so the buffer is sliced as bytes and decoded afterwards.
// Slicing characters would cut short any message with non-ASCII text in it (a
// comment in a source file, say) and the stream would never get back in sync.
let inbuf = Buffer.alloc(0);
function feed(chunk) {
  inbuf = Buffer.concat([inbuf, chunk]);
  for (;;) {
    const split = inbuf.indexOf('\r\n\r\n');
    if (split < 0) return;
    const header = inbuf.slice(0, split).toString('ascii');
    const m = /content-length:\s*(\d+)/i.exec(header);
    if (!m) { inbuf = inbuf.slice(split + 4); continue; }
    const len = parseInt(m[1], 10);
    if (inbuf.length < split + 4 + len) return;
    const body = inbuf.slice(split + 4, split + 4 + len).toString('utf8');
    inbuf = inbuf.slice(split + 4 + len);
    let msg = null;
    try { msg = JSON.parse(body); } catch (e) { continue; }
    try { dispatch(msg); } catch (e) { fail(msg, e); }
  }
}

function send(obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}
function reply(id, result) { if (id !== undefined && id !== null) send({ jsonrpc: '2.0', id, result }); }
function fail(msg, e) {
  if (msg && msg.id !== undefined && msg.id !== null) {
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: String(e && e.stack || e) } });
  } else {
    log(`unhandled: ${e && e.stack || e}`);
  }
}
function log(text) { send({ jsonrpc: '2.0', method: 'window/logMessage', params: { type: 3, message: text } }); }

// ------------------------------------------------------------------- state
// Open documents are keyed by filesystem path. Clients escape URIs differently,
// so one file can arrive under two URIs, and a lookup that missed would compile
// the copy on disk instead of the edited buffer. The client's own URI is kept
// too, so diagnostics go back to the document it opened.
const docs = new Map();       // fs path -> { text, uri }
let wordBin = null;           // resolved path to the compiler
let rootDir = null;           // workspace root; the cwd builds run in
let shuttingDown = false;
const debounce = new Map();   // uri -> timer

function uriToPath(uri) {
  if (!uri.startsWith('file://')) return uri;
  let p = decodeURIComponent(uri.slice(7));
  // file:///c%3A/x on Windows arrives with a leading slash before the drive.
  if (/^\/[a-zA-Z]:/.test(p)) p = p.slice(1);
  return p;
}
function pathToUri(p) {
  let abs = path.resolve(p).replace(/\\/g, '/');
  if (!abs.startsWith('/')) abs = '/' + abs;
  return 'file://' + abs.split('/').map(encodeURIComponent).join('/').replace(/%3A/gi, ':');
}
function key(p) { return path.resolve(p); }
function textOf(p) {
  const d = docs.get(key(p));
  if (d) return d.text;
  try { return fs.readFileSync(p, 'utf8'); } catch (e) { return null; }
}
// Publish against the URI the client opened, when it opened one.
function uriFor(p) {
  const d = docs.get(key(p));
  return d ? d.uri : pathToUri(p);
}

// ------------------------------------------------- finding the word binary
// In order: the path the editor passed, $WORD_BIN, `word` in the workspace root
// (a checkout of this repo has one), then PATH. When there's none, onInitialize
// tells the user once, because no diagnostics at all would look the same as a
// program with no errors.
function resolveWord(hint) {
  const exe = process.platform === 'win32' ? 'word.exe' : 'word';
  const tries = [];
  if (hint) tries.push(hint);
  if (process.env.WORD_BIN) tries.push(process.env.WORD_BIN);
  if (rootDir) tries.push(path.join(rootDir, exe));
  for (const t of tries) {
    try { fs.accessSync(t, fs.constants.X_OK); return t; } catch (e) { /* next */ }
  }
  const which = spawnSync(process.platform === 'win32' ? 'where' : 'which', [exe], { encoding: 'utf8' });
  if (which.status === 0) {
    const first = String(which.stdout).split(/\r?\n/)[0].trim();
    if (first) return first;
  }
  return null;
}

// ------------------------------------------------------------- the scanner
// The scanner works line by line, like word: a newline ends a statement and
// indentation opens a block (SPEC 2.2), so a definition is a line at column 0
// and its body is the indented lines under it. That's enough for an outline and
// for scope. It isn't a parser, and it never decides whether a program is
// correct.

// Replace every string, character literal and comment with spaces, keeping the
// line's length so every column stays where it was. The code below can then
// use plain regexes without matching inside a literal.
function blank(line) {
  const out = line.split('');
  let i = 0;
  while (i < line.length) {
    const c = line[i];
    if (c === '/' && line[i + 1] === '/') { for (let j = i; j < line.length; j++) out[j] = ' '; break; }
    if (c === '"' || c === "'") {
      const quote = c;
      out[i] = ' ';
      i++;
      while (i < line.length) {
        if (line[i] === '\\' && i + 1 < line.length) { out[i] = ' '; out[i + 1] = ' '; i += 2; continue; }
        const end = line[i] === quote;
        out[i] = ' ';
        i++;
        if (end) break;
      }
      continue;
    }
    i++;
  }
  return out.join('');
}

const IDENT = /[A-Za-z_][A-Za-z0-9_]*/g;

// Every definition, hook, import and local binding in one file.
function scan(text) {
  const lines = text.split(/\r?\n/);
  const bare = lines.map(blank);
  const funcs = [], hooks = [], imports = [];
  let current = null;   // the definition whose body we are inside
  let top = null;       // the file's top-level statements, one scope (SPEC 8.1)

  const closeAt = (i) => { if (current && current !== top) { current.endLine = i - 1; } current = null; };
  // The top level is one scope for the whole file: a name bound on the first
  // line is in scope on the last. It starts at line 0, so for a line inside a
  // definition the definition wins (enclosing() takes the latest start).
  const topScope = () => {
    if (!top) {
      top = { name: null, line: 0, col: 0, endLine: lines.length - 1,
              params: [], locals: [], hook: null, top: true };
      funcs.push(top);
    }
    return top;
  };

  // A column-0 `name(...)` line is a definition only when something is indented
  // under it. Both the definition `twice(n)` and the call `out(total)` are a
  // name and a parenthesised list, and that's the only difference. The language
  // works the same way: a header with nothing indented under it is an error, and
  // there are no one-line block forms (SPEC 2.2).
  const opensABlock = (after) => {
    for (let k = after + 1; k < lines.length; k++) {
      const b2 = bare[k];
      if (!b2.trim()) continue;
      return b2.length - b2.replace(/^ */, '').length > 0;
    }
    return false;
  };

  for (let i = 0; i < lines.length; i++) {
    const b = bare[i];
    if (!b.trim()) continue;                       // blank and comment-only lines open nothing
    const indent = b.length - b.replace(/^ */, '').length;
    if (indent > 0) {
      if (current) collectBindings(b, i, current);
      continue;
    }
    closeAt(i);

    let m = /^import\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(b);
    if (m) { imports.push({ name: m[1], line: i, col: b.indexOf(m[1], 6) }); continue; }

    m = /^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(before|after)\s*$/.exec(b);
    if (m) {
      current = { name: m[1], line: i, col: 0, endLine: lines.length - 1, params: [], locals: [], hook: m[2] };
      hooks.push(current);
      continue;
    }

    m = /^([A-Za-z_][A-Za-z0-9_]*)\s*\(/.exec(b);
    if (m) {
      // Parameters may wrap across lines inside the unmatched `(` (SPEC 2.2),
      // so keep taking lines until the parenthesis closes.
      let text2 = b.slice(m[0].length), j = i, depth = 1;
      while (j < lines.length) {
        let k = 0;
        for (; k < text2.length && depth > 0; k++) {
          if (text2[k] === '(') depth++;
          else if (text2[k] === ')') depth--;
        }
        if (depth === 0) { text2 = text2.slice(0, k - 1); break; }
        j++;
        if (j >= lines.length) break;
        text2 += '\n' + bare[j];
      }
      if (opensABlock(j)) {
        const params = [];
        for (const p of text2.split(',')) {
          const pm = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*$/.exec(p.replace(/\n/g, ' '));
          if (pm) params.push(pm[1]);
        }
        current = { name: m[1], line: i, col: 0, endLine: lines.length - 1, params, locals: [], hook: null,
                    doc: docComment(lines, i), signature: `${m[1]}(${params.join(', ')})` };
        funcs.push(current);
        i = j;
        continue;
      }
      // Otherwise it's a top-level call. It binds nothing, but it's still
      // top-level code, so fall through.
    }
    // Any other column-0 line is top-level program text (SPEC 8.1).
    current = topScope();
    collectBindings(b, i, current);
    continue;
  }
  if (current && current !== top) current.endLine = lines.length - 1;
  return { lines, bare, funcs, hooks, imports };
}

// `x = ...` binds x; `loop x in y` binds x. `x[i] = ...` and `x == y` do not.
function collectBindings(b, line, into) {
  let m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)/.exec(b);
  if (m) { addLocal(into, m[1], line, b.indexOf(m[1])); return; }
  m = /^\s*loop\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s/.exec(b);
  if (m) { addLocal(into, m[1], line, b.indexOf(m[1], 4)); }
}
function addLocal(into, name, line, col) {
  if (into.params.includes(name)) return;
  if (into.locals.some((l) => l.name === name)) return;
  into.locals.push({ name, line, col });
}

// The `//` lines directly above a definition, which is where this codebase
// explains one.
function docComment(lines, at) {
  const out = [];
  for (let i = at - 1; i >= 0; i--) {
    const t = lines[i].trim();
    if (!t.startsWith('//')) break;
    out.unshift(t.replace(/^\/\/ ?/, ''));
  }
  return out.join('\n');
}

// Which definition encloses a line.
function enclosing(model, line) {
  let best = null;
  for (const d of model.funcs.concat(model.hooks)) {
    if (line >= d.line && line <= d.endLine) { if (!best || d.line > best.line) best = d; }
  }
  return best;
}

// The identifier under a position, with its exact range.
function wordAt(model, line, ch) {
  const b = model.bare[line];
  if (b === undefined) return null;
  IDENT.lastIndex = 0;
  let m;
  while ((m = IDENT.exec(b)) !== null) {
    if (ch >= m.index && ch <= m.index + m[0].length) {
      return { name: m[0], line, start: m.index, end: m.index + m[0].length };
    }
  }
  return null;
}

// ------------------------------------------------------------ the program
// The files that make up the program a given file belongs to. A folder with an
// `app.w` is one program (SPEC 11): building app.w compiles in the folder's
// other .w files, so any file there is checked by building app.w. In a folder
// without one, a file builds alone, so a scratch directory of unrelated `.w`
// files pulls in nothing.
function programOf(p) {
  const dir = path.dirname(p);
  const entry = path.join(dir, 'app.w');
  let hasEntry = false;
  try { hasEntry = fs.statSync(entry).isFile(); } catch (e) { hasEntry = false; }
  if (path.basename(p) !== 'app.w' && !hasEntry) return { entry: p, files: [p], dir };
  let names = [];
  try { names = fs.readdirSync(dir).filter((n) => n.endsWith('.w')).sort(); } catch (e) { names = [path.basename(p)]; }
  const files = names.map((n) => path.join(dir, n));
  if (!files.includes(p)) files.push(p);
  return { entry, files, dir };
}

// Every definition visible from a file, across the whole program.
function programModel(p) {
  const prog = programOf(p);
  const out = { prog, byFile: new Map(), funcs: [], hooks: [] };
  for (const f of prog.files) {
    const t = textOf(f);
    if (t === null) continue;
    const m = scan(t);
    out.byFile.set(f, m);
    for (const d of m.funcs) if (d.name) out.funcs.push(Object.assign({ file: f }, d));
    for (const h of m.hooks) out.hooks.push(Object.assign({ file: f }, h));
  }
  return out;
}

// ----------------------------------------------------------- diagnostics
// Only the compiler decides whether a program is wrong, so run it. The buffer
// being edited isn't on disk, so the program's files are copied into a temp
// directory, with the open buffers in place of the saved files. The directory
// listing has to match too, since a folder build reads it.
//
// The build runs in the workspace root. The net library is inside the word
// binary, so the working directory doesn't change the result; the root is just
// a fixed place to run from.
function buildDiagnostics(p) {
  if (!wordBin) return null;
  const prog = programOf(p);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'word-lsp-'));
  try {
    for (const f of prog.files) {
      const t = textOf(f);
      if (t === null) continue;
      fs.writeFileSync(path.join(tmp, path.basename(f)), t, 'utf8');
    }
    const entry = path.join(tmp, path.basename(prog.entry));
    if (!fs.existsSync(entry)) return null;
    // `-asm` runs everything that can report an error in the program and stops
    // before assembling and linking. On compiler/word.w, the largest word
    // program, that's about 0.25 s against 0.65 s for a full build, and no
    // binary gets written to disk on every keystroke. The assembly goes to
    // stdout, which is sent to the null device instead of piped back here.
    const r = spawnSync(wordBin, ['build', '-asm', entry],
                        { cwd: rootDir || prog.dir, encoding: 'utf8', timeout: 20000,
                          stdio: ['ignore', 'ignore', 'pipe'] });
    if (r.error) { log(`word build failed to run: ${r.error.message}`); return null; }
    return parseDiagnostics(String(r.stderr || ''), tmp, prog);
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { /* nothing to do */ }
  }
}

// `path:line:col: message`, one-based. The compiler stops at the first error,
// so there's only one. A line without that prefix is still a failure (`cannot
// read helper.w`, say), so it's shown on the entry file instead of dropped.
function parseDiagnostics(stderr, tmp, prog) {
  const byFile = new Map();
  for (const f of prog.files) byFile.set(f, []);
  const put = (file, d) => {
    if (!byFile.has(file)) byFile.set(file, []);
    byFile.get(file).push(d);
  };
  for (const raw of stderr.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const m = /^(.*?):(\d+):(\d+):\s*(.*)$/.exec(line);
    if (!m) {
      put(prog.entry, diag(0, 0, 0, line));
      continue;
    }
    const [, where, ln, col, message] = m;
    // The reported path is relative to the temp entry, or absolute inside it.
    const base = path.basename(where);
    let target = prog.files.find((f) => path.basename(f) === base);
    if (!target) {
      // A bundled net module (net.w, tls.w, ...) or another file outside the
      // program: keep the message, but show it on the entry file.
      put(prog.entry, diag(0, 0, 0, `${where}:${ln}:${col}: ${message}`));
      continue;
    }
    const l = Math.max(0, parseInt(ln, 10) - 1);
    const c = Math.max(0, parseInt(col, 10) - 1);
    put(target, diag(l, c, endOfSymbol(target, l, c), message));
  }
  return byFile;
}
function diag(line, start, end, message) {
  return {
    range: { start: { line, character: start }, end: { line, character: Math.max(end, start + 1) } },
    severity: 1, source: 'word', message
  };
}
// The compiler gives a position, not a range. Underline the identifier or
// number that starts there, which is easier to see than one character.
function endOfSymbol(file, line, col) {
  const t = textOf(file);
  if (t === null) return col + 1;
  const lines = t.split(/\r?\n/);
  const l = lines[line];
  if (l === undefined) return col + 1;
  const m = /^[A-Za-z_][A-Za-z0-9_]*|^[0-9]+/.exec(l.slice(col));
  return col + (m ? m[0].length : 1);
}

function publish(p) {
  const byFile = buildDiagnostics(p);
  if (byFile === null) return;
  for (const [file, list] of byFile) {
    send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics',
           params: { uri: uriFor(file), diagnostics: list } });
  }
}
function schedule(uri) {
  const p = uriToPath(uri);
  if (debounce.has(uri)) clearTimeout(debounce.get(uri));
  debounce.set(uri, setTimeout(() => { debounce.delete(uri); try { publish(p); } catch (e) { log(String(e)); } }, 200));
}

// ------------------------------------------------------------- capabilities
function dispatch(msg) {
  const { id, method, params } = msg;
  switch (method) {
    case 'initialize':        return onInitialize(id, params);
    case 'initialized':       return;
    case 'shutdown':          shuttingDown = true; return reply(id, null);
    case 'exit':              process.exit(shuttingDown ? 0 : 1);
    case 'textDocument/didOpen':
      docs.set(key(uriToPath(params.textDocument.uri)),
               { text: params.textDocument.text, uri: params.textDocument.uri });
      return schedule(params.textDocument.uri);
    case 'textDocument/didChange': {
      // Registered as full sync: the last change carries the whole document.
      const c = params.contentChanges[params.contentChanges.length - 1];
      if (c) docs.set(key(uriToPath(params.textDocument.uri)),
                      { text: c.text, uri: params.textDocument.uri });
      return schedule(params.textDocument.uri);
    }
    case 'textDocument/didSave':  return schedule(params.textDocument.uri);
    case 'textDocument/didClose':
      docs.delete(key(uriToPath(params.textDocument.uri)));
      send({ jsonrpc: '2.0', method: 'textDocument/publishDiagnostics',
             params: { uri: params.textDocument.uri, diagnostics: [] } });
      return;
    case 'textDocument/definition':     return reply(id, onDefinition(params));
    case 'textDocument/hover':          return reply(id, onHover(params));
    case 'textDocument/documentSymbol': return reply(id, onSymbols(params));
    case 'textDocument/formatting':     return reply(id, onFormat(params));
    case 'textDocument/completion':     return reply(id, onCompletion(params));
    case 'textDocument/references':     return reply(id, onReferences(params));
    case 'textDocument/prepareRename':  return onPrepareRename(id, params);
    case 'textDocument/rename':         return onRename(id, params);
    default:
      // A request we do not answer still needs an answer, or the editor waits.
      if (id !== undefined && id !== null) reply(id, null);
  }
}

function onInitialize(id, params) {
  rootDir = params.rootUri ? uriToPath(params.rootUri)
          : (params.workspaceFolders && params.workspaceFolders[0] ? uriToPath(params.workspaceFolders[0].uri)
          : (params.rootPath || null));
  const opts = params.initializationOptions || {};
  wordBin = resolveWord(opts.wordPath || argFlag('--word'));
  if (!wordBin) {
    send({ jsonrpc: '2.0', method: 'window/showMessage', params: { type: 2,
      message: 'word: no compiler found, so there are no diagnostics. Set word.compilerPath, or put `word` on PATH.' } });
  }
  reply(id, {
    capabilities: {
      textDocumentSync: 1,                    // full text on every change
      definitionProvider: true,
      hoverProvider: true,
      documentSymbolProvider: true,
      documentFormattingProvider: true,
      referencesProvider: true,
      renameProvider: { prepareProvider: true },
      completionProvider: { triggerCharacters: [] }
    },
    serverInfo: { name: 'word-language-server', version: '0.1.0' }
  });
}
function argFlag(flag) {
  const i = process.argv.indexOf(flag);
  return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null;
}

// ------------------------------------------------------------- definition
function onDefinition(params) {
  const p = uriToPath(params.textDocument.uri);
  const t = textOf(p);
  if (t === null) return null;
  const model = scan(t);
  const w = wordAt(model, params.position.line, params.position.character);
  if (!w) return null;

  // A local wins over a function of the same name, as it does in the compiler,
  // so look in the enclosing definition first.
  const here = enclosing(model, params.position.line);
  if (here) {
    const local = here.locals.find((l) => l.name === w.name);
    if (local) return loc(p, local.line, local.col, w.name.length);
    const pi = here.params.indexOf(w.name);
    if (pi >= 0) {
      const col = model.bare[here.line].indexOf(w.name, here.name ? here.name.length : 0);
      return loc(p, here.line, col < 0 ? 0 : col, w.name.length);
    }
  }
  const pm = programModel(p);
  const f = pm.funcs.find((d) => d.name === w.name);
  if (f) return loc(f.file, f.line, 0, w.name.length);
  return null;
}
function loc(file, line, col, len) {
  return { uri: uriFor(file),
           range: { start: { line, character: col }, end: { line, character: col + len } } };
}

// ------------------------------------------------------------------ hover
function onHover(params) {
  const p = uriToPath(params.textDocument.uri);
  const t = textOf(p);
  if (t === null) return null;
  const model = scan(t);
  const w = wordAt(model, params.position.line, params.position.character);
  if (!w) return null;
  const md = describe(w.name, p, model, params.position.line);
  if (!md) return null;
  return { contents: { kind: 'markdown', value: md },
           range: { start: { line: w.line, character: w.start }, end: { line: w.line, character: w.end } } };
}

function describe(name, p, model, line) {
  const here = enclosing(model, line);
  if (here) {
    if (here.params.includes(name)) return `\`\`\`word\n${name}\n\`\`\`\n\nParameter of \`${here.name || 'the top level'}\`.`;
    if (here.locals.some((l) => l.name === name)) return `\`\`\`word\n${name}\n\`\`\`\n\nLocal in \`${here.name || 'the top level'}\`.`;
  }
  const pm = programModel(p);
  const f = pm.funcs.find((d) => d.name === name);
  if (f) {
    let md = '```word\n' + f.signature + '\n```';
    const hs = pm.hooks.filter((h) => h.name === name).map((h) => '`:' + h.hook + '`');
    if (hs.length) md += `\n\nGuarded by ${hs.join(' and ')}.`;
    if (f.doc) md += '\n\n' + f.doc;
    if (path.basename(f.file) !== path.basename(p)) md += `\n\nDefined in \`${path.basename(f.file)}\`.`;
    return md;
  }
  const b = DATA.builtins[name];
  if (b) return '```word\n' + b.signature + '\n```\n\nBuiltin (SPEC §9).\n\n' + b.doc;
  for (const mod of DATA.modules) {
    const mf = DATA.moduleFuncs[mod] && DATA.moduleFuncs[mod][name];
    if (mf) return '```word\n' + mf.signature + '\n```\n\nFrom module `' + mod + '`, no import needed (SPEC §11).\n\n' + mf.doc;
  }
  if (DATA.singletons.includes(name)) {
    return '```word\n' + name + '\n```\n\nOne of the four singletons (SPEC §3.8): `null`, `false`, `true`, `none`. Reserved, so it cannot be assigned to.';
  }
  if (DATA.keywords.includes(name)) return '```word\n' + name + '\n```\n\nKeyword (SPEC §2.4).';
  return null;
}

// --------------------------------------------------------------- symbols
function onSymbols(params) {
  const p = uriToPath(params.textDocument.uri);
  const t = textOf(p);
  if (t === null) return [];
  const model = scan(t);
  const out = [];
  for (const f of model.funcs) {
    if (!f.name) continue;
    out.push({ name: f.signature || f.name, kind: 12,  // Function
               range: span(f), selectionRange: onlyName(f, model) });
  }
  for (const h of model.hooks) {
    out.push({ name: `${h.name}:${h.hook}`, kind: 6,   // Method
               range: span(h), selectionRange: onlyName(h, model) });
  }
  out.sort((a, b) => a.range.start.line - b.range.start.line);
  return out;
}
function span(d) {
  return { start: { line: d.line, character: 0 }, end: { line: Math.max(d.line, d.endLine), character: 0 } };
}
function onlyName(d, model) {
  return { start: { line: d.line, character: 0 }, end: { line: d.line, character: d.name.length } };
}

// ------------------------------------------------------------- formatting
// `word format` is the one canonical layout (SPEC 2.2). It rewrites the file in
// place, so it runs on a copy. It lexes its own output again and refuses to
// write unless the tokens are unchanged, so a failure here means no edit, never
// a mangled buffer.
function onFormat(params) {
  if (!wordBin) return null;
  const p = uriToPath(params.textDocument.uri);
  const before = textOf(p);
  if (before === null) return null;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'word-fmt-'));
  try {
    const f = path.join(tmp, path.basename(p));
    fs.writeFileSync(f, before, 'utf8');
    const r = spawnSync(wordBin, ['format', f], { cwd: rootDir || path.dirname(p), encoding: 'utf8', timeout: 20000 });
    if (r.error || r.status !== 0) return null;
    const after = fs.readFileSync(f, 'utf8');
    if (after === before) return [];
    const lines = before.split(/\r?\n/);
    return [{ range: { start: { line: 0, character: 0 },
                       end: { line: lines.length - 1, character: lines[lines.length - 1].length } },
              newText: after }];
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { /* nothing to do */ }
  }
}

// ------------------------------------------------------------- completion
function onCompletion(params) {
  const p = uriToPath(params.textDocument.uri);
  const t = textOf(p);
  if (t === null) return null;
  const model = scan(t);
  const line = model.lines[params.position.line] || '';
  const upto = line.slice(0, params.position.character);

  // `import ` takes one of a closed list, and nothing else is legal there.
  if (/^\s*import\s+[A-Za-z_]*$/.test(upto)) {
    return DATA.modules.map((m) => ({ label: m, kind: 9, detail: 'module (SPEC §12)' }));
  }
  // A kind test has a closed list too: kind() answers eight names, and
  // comparing it with any other name is a compile error.
  if (/kind\s*\([^)]*\)\s*[=!]=\s*"[a-z]*$/.test(upto)) {
    return DATA.kindNames.map((k) => ({ label: k, kind: 12, detail: 'kind (SPEC §9)' }));
  }

  const items = [];
  const here = enclosing(model, params.position.line);
  if (here) {
    for (const n of here.params) items.push({ label: n, kind: 6, detail: 'parameter', sortText: '0' + n });
    for (const l of here.locals) items.push({ label: l.name, kind: 6, detail: 'local', sortText: '0' + l.name });
    if (here.hook === 'after') items.push({ label: 'result', kind: 6, detail: 'the value being returned (SPEC §8.2)', sortText: '0result' });
  }
  const pm = programModel(p);
  const seen = new Set(items.map((i) => i.label));
  for (const f of pm.funcs) {
    if (!f.name || seen.has(f.name)) continue;
    seen.add(f.name);
    items.push({ label: f.name, kind: 3, detail: f.signature,
                 documentation: f.doc || undefined, sortText: '1' + f.name });
  }
  for (const [name, b] of Object.entries(DATA.builtins)) {
    if (seen.has(name)) continue;
    items.push({ label: name, kind: 3, detail: b.signature, sortText: '2' + name,
                 documentation: { kind: 'markdown', value: b.doc } });
  }
  for (const mod of DATA.modules) {
    if (mod === 'sys') continue;   // the toolchain's own module, not for programs (SPEC 12.5)
    for (const [name, mf] of Object.entries(DATA.moduleFuncs[mod] || {})) {
      if (seen.has(name)) continue;
      seen.add(name);
      items.push({ label: name, kind: 3, detail: `${mf.signature} (${mod})`, sortText: '3' + name,
                   documentation: { kind: 'markdown', value: mf.doc } });
    }
  }
  for (const k of DATA.keywords) items.push({ label: k, kind: 14, sortText: '4' + k });
  for (const s of DATA.singletons) items.push({ label: s, kind: 21, detail: 'singleton (SPEC §3.8)', sortText: '4' + s });
  return items;
}

// --------------------------------------------------------- references/rename
// Occurrences of a name: a local only within its own definition, a function
// across the whole program (its definition, its calls, and its `name:before` /
// `name:after` hook headers).
function occurrences(name, p, model, atLine) {
  const here = enclosing(model, atLine);
  const isLocal = here && (here.params.includes(name) || here.locals.some((l) => l.name === name));
  const hits = [];
  const walk = (file, m, fromLine, toLine) => {
    for (let i = fromLine; i <= toLine && i < m.bare.length; i++) {
      const b = m.bare[i];
      IDENT.lastIndex = 0;
      let g;
      while ((g = IDENT.exec(b)) !== null) {
        if (g[0] !== name) continue;
        // `x:before` isn't a call, but it has to be renamed with the function,
        // and the word before the `:` is the name, so it counts.
        hits.push({ file, line: i, start: g.index, end: g.index + name.length });
      }
    }
  };
  if (isLocal) { walk(p, model, here.line, here.endLine); return { hits, scope: 'local' }; }
  const pm = programModel(p);
  for (const [file, m] of pm.byFile) walk(file, m, 0, m.bare.length - 1);
  return { hits, scope: 'program' };
}

function onReferences(params) {
  const p = uriToPath(params.textDocument.uri);
  const t = textOf(p);
  if (t === null) return null;
  const model = scan(t);
  const w = wordAt(model, params.position.line, params.position.character);
  if (!w) return null;
  const { hits } = occurrences(w.name, p, model, params.position.line);
  return hits.map((h) => loc(h.file, h.line, h.start, w.name.length));
}

// What a name is, when the program does not define it.
function notOurs(name) {
  if (DATA.keywords.includes(name)) return `a keyword (SPEC §2.4)`;
  if (DATA.singletons.includes(name)) return `a singleton literal, not a name (SPEC §3.8)`;
  if (DATA.builtins[name]) return `a builtin (SPEC §9)`;
  for (const mod of DATA.modules) {
    if (DATA.moduleFuncs[mod] && DATA.moduleFuncs[mod][name]) return `from module '${mod}' (SPEC §12)`;
  }
  return null;
}

// Does the program itself bind this name here, as a parameter, a local or a
// function of its own? That decides a rename. Whether it's also a builtin
// doesn't: builtins are ordinary identifiers a program may shadow (SPEC §2.5),
// and then the program's definition wins. So a program's own `len(x)` can be
// renamed, and `len` in a program that never defines one can't.
function boundHere(name, p, model, line) {
  const here = enclosing(model, line);
  if (here && (here.params.includes(name) || here.locals.some((l) => l.name === name))) return true;
  return programModel(p).funcs.some((d) => d.name === name);
}

// Refuse to rename a keyword, singleton, builtin or module function the program
// doesn't define itself. Renaming its uses wouldn't rename what they refer to.
function renameRefusal(name, p, model, line) {
  if (boundHere(name, p, model, line)) return null;
  const what = notOurs(name);
  return what ? `'${name}' is ${what}, so it is not this program's to rename.` : null;
}

// The new name is checked separately. A keyword or a singleton can't be a name
// at all. A builtin or module function could be (the program would shadow it),
// but that changes what every existing call to it does, which nobody means to
// do with a rename, so it's refused with the reason.
function targetRefusal(newName) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(newName)) return `'${newName}' is not an identifier (SPEC §2.5).`;
  if (DATA.keywords.includes(newName)) return `'${newName}' is a keyword (SPEC §2.4) and cannot be a name.`;
  if (DATA.singletons.includes(newName)) return `'${newName}' is a singleton literal (SPEC §3.8) and cannot be a name.`;
  const what = notOurs(newName);
  if (what) return `'${newName}' is ${what}. A program may shadow one (SPEC §2.5), but renaming onto it would change what every existing call to '${newName}' means.`;
  return null;
}

function onPrepareRename(id, params) {
  const p = uriToPath(params.textDocument.uri);
  const t = textOf(p);
  if (t === null) return reply(id, null);
  const model = scan(t);
  const w = wordAt(model, params.position.line, params.position.character);
  if (!w) return reply(id, null);
  const why = renameRefusal(w.name, p, model, params.position.line);
  if (why) return send({ jsonrpc: '2.0', id, error: { code: -32602, message: why } });
  return reply(id, { start: { line: w.line, character: w.start }, end: { line: w.line, character: w.end } });
}

function onRename(id, params) {
  const p = uriToPath(params.textDocument.uri);
  const t = textOf(p);
  if (t === null) return reply(id, null);
  const model = scan(t);
  const w = wordAt(model, params.position.line, params.position.character);
  if (!w) return reply(id, null);
  const why = renameRefusal(w.name, p, model, params.position.line);
  if (why) return send({ jsonrpc: '2.0', id, error: { code: -32602, message: why } });
  const taken = targetRefusal(params.newName);
  if (taken) return send({ jsonrpc: '2.0', id, error: { code: -32602, message: taken } });
  const newName = params.newName;

  const { hits } = occurrences(w.name, p, model, params.position.line);
  const changes = {};
  for (const h of hits) {
    const uri = uriFor(h.file);
    (changes[uri] = changes[uri] || []).push({
      range: { start: { line: h.line, character: h.start }, end: { line: h.line, character: h.end } },
      newText: newName
    });
  }
  reply(id, { changes });
}

// Run by an editor, speak the protocol. Loaded with require() (which is how
// dev/toolchain/test_outline.js checks the scanner against the compiler's own
// function labels), export the pieces and do nothing else.
if (require.main === module) {
  process.stdin.on('data', feed);
} else {
  module.exports = { scan, blank, programOf, describe, DATA };
}
