// extension.js: the VS Code side of the word language server.
//
// It talks LSP to server.js over stdio instead of loading it, so the same
// server.js works in Neovim, Helix, Emacs, Zed or any other editor that speaks
// the protocol, and only this file knows about VS Code.
//
// It uses the raw protocol instead of `vscode-languageclient` because nothing
// else in this repo has dependencies, and I didn't want an editor extension to
// be the first. The part of the protocol used here is small.

'use strict';
const vscode = require('vscode');
const path = require('path');
const { spawn } = require('child_process');

let client = null;
let diagnostics = null;
let output = null;

function activate(context) {
  diagnostics = vscode.languages.createDiagnosticCollection('word');
  output = vscode.window.createOutputChannel('word');
  context.subscriptions.push(diagnostics, output);

  const cfg = () => vscode.workspace.getConfiguration('word');
  if (cfg().get('languageServer.enable') === false) return;

  client = new Client(context);
  client.start();

  context.subscriptions.push(vscode.commands.registerCommand('word.restartServer', () => {
    client.stop();
    client.start();
    vscode.window.showInformationMessage('word: language server restarted.');
  }));
  context.subscriptions.push({ dispose: () => client && client.stop() });

  registerProviders(context);
  registerSync(context);
}

function deactivate() { if (client) client.stop(); }

// ------------------------------------------------------------------ client
class Client {
  constructor(context) {
    this.context = context;
    this.proc = null;
    this.buf = Buffer.alloc(0);
    this.nextId = 1;
    this.pending = new Map();
    this.ready = null;
  }

  start() {
    const server = this.context.asAbsolutePath(path.join('server.js'));
    const cfg = vscode.workspace.getConfiguration('word');
    const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
    this.proc = spawn(process.execPath, [server, '--stdio'], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc.stdout.on('data', (c) => this.feed(c));
    this.proc.stderr.on('data', (c) => output.append(String(c)));
    this.proc.on('exit', (code) => { if (code) output.appendLine(`word language server exited with ${code}`); });

    this.ready = this.request('initialize', {
      processId: process.pid,
      rootUri: folder ? folder.uri.toString() : null,
      workspaceFolders: folder ? [{ uri: folder.uri.toString(), name: folder.name }] : null,
      capabilities: {},
      initializationOptions: { wordPath: cfg.get('compilerPath') || null }
    }).then(() => { this.notify('initialized', {}); });

    // Send the word documents that are already open when the extension starts.
    this.ready.then(() => {
      for (const doc of vscode.workspace.textDocuments) {
        if (doc.languageId === 'word') this.didOpen(doc);
      }
    });
  }

  stop() {
    if (!this.proc) return;
    try { this.notify('exit', null); } catch (e) { /* already gone */ }
    try { this.proc.kill(); } catch (e) { /* already gone */ }
    this.proc = null;
    this.pending.clear();
    if (diagnostics) diagnostics.clear();
  }

  feed(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    for (;;) {
      const split = this.buf.indexOf('\r\n\r\n');
      if (split < 0) return;
      const m = /Content-Length:\s*(\d+)/i.exec(this.buf.slice(0, split).toString('ascii'));
      if (!m) { this.buf = this.buf.slice(split + 4); continue; }
      const len = parseInt(m[1], 10);
      if (this.buf.length < split + 4 + len) return;
      const body = this.buf.slice(split + 4, split + 4 + len).toString('utf8');
      this.buf = this.buf.slice(split + 4 + len);
      let msg;
      try { msg = JSON.parse(body); } catch (e) { continue; }
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const { resolve } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        resolve(msg);
      } else {
        this.onNotification(msg);
      }
    }
  }

  onNotification(msg) {
    if (msg.method === 'textDocument/publishDiagnostics') {
      const uri = vscode.Uri.parse(msg.params.uri);
      diagnostics.set(uri, msg.params.diagnostics.map((d) => {
        const dd = new vscode.Diagnostic(toRange(d.range), d.message, vscode.DiagnosticSeverity.Error);
        dd.source = 'word';
        return dd;
      }));
    } else if (msg.method === 'window/showMessage') {
      const show = [null, vscode.window.showErrorMessage, vscode.window.showWarningMessage,
                    vscode.window.showInformationMessage, vscode.window.showInformationMessage][msg.params.type] ||
                   vscode.window.showInformationMessage;
      show(msg.params.message);
    } else if (msg.method === 'window/logMessage') {
      output.appendLine(msg.params.message);
    }
  }

  send(obj) {
    if (!this.proc) return;
    const body = Buffer.from(JSON.stringify(Object.assign({ jsonrpc: '2.0' }, obj)), 'utf8');
    this.proc.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.proc.stdin.write(body);
  }
  notify(method, params) { this.send({ method, params }); }
  request(method, params) {
    if (!this.proc) return Promise.resolve({ result: null });
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.pending.set(id, { resolve });
      this.send({ id, method, params });
    });
  }
  // Every provider below asks through this. A failed request is logged to the
  // output channel and the providers treat it as no answer, so VS Code carries
  // on without showing the user an error they can't do anything about.
  async ask(method, params) {
    if (!this.proc) return null;
    await this.ready;
    const msg = await this.request(method, params);
    if (msg.error) { output.appendLine(`${method}: ${msg.error.message}`); return { error: msg.error }; }
    return { result: msg.result };
  }

  didOpen(doc) {
    this.notify('textDocument/didOpen', { textDocument: {
      uri: doc.uri.toString(), languageId: 'word', version: doc.version, text: doc.getText() } });
  }
}

// ------------------------------------------------------------------- sync
function registerSync(context) {
  const isWord = (doc) => doc && doc.languageId === 'word';
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument((doc) => { if (isWord(doc)) client.didOpen(doc); }),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (!isWord(e.document)) return;
      client.notify('textDocument/didChange', {
        textDocument: { uri: e.document.uri.toString(), version: e.document.version },
        contentChanges: [{ text: e.document.getText() }]
      });
    }),
    vscode.workspace.onDidSaveTextDocument((doc) => {
      if (isWord(doc)) client.notify('textDocument/didSave', { textDocument: { uri: doc.uri.toString() } });
    }),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      if (isWord(doc)) client.notify('textDocument/didClose', { textDocument: { uri: doc.uri.toString() } });
    })
  );
}

// -------------------------------------------------------------- providers
const SEL = { language: 'word', scheme: 'file' };
const toPos = (p) => new vscode.Position(p.line, p.character);
const toRange = (r) => new vscode.Range(toPos(r.start), toPos(r.end));
const at = (doc, pos) => ({ textDocument: { uri: doc.uri.toString() }, position: { line: pos.line, character: pos.character } });

function registerProviders(context) {
  context.subscriptions.push(
    vscode.languages.registerDefinitionProvider(SEL, {
      async provideDefinition(doc, pos) {
        const r = await client.ask('textDocument/definition', at(doc, pos));
        if (!r || !r.result) return null;
        return new vscode.Location(vscode.Uri.parse(r.result.uri), toRange(r.result.range));
      }
    }),

    vscode.languages.registerHoverProvider(SEL, {
      async provideHover(doc, pos) {
        const r = await client.ask('textDocument/hover', at(doc, pos));
        if (!r || !r.result) return null;
        const md = new vscode.MarkdownString(r.result.contents.value);
        return new vscode.Hover(md, r.result.range ? toRange(r.result.range) : undefined);
      }
    }),

    vscode.languages.registerDocumentSymbolProvider(SEL, {
      async provideDocumentSymbols(doc) {
        const r = await client.ask('textDocument/documentSymbol', { textDocument: { uri: doc.uri.toString() } });
        if (!r || !r.result) return [];
        return r.result.map((s) => new vscode.DocumentSymbol(
          s.name, '', s.kind === 6 ? vscode.SymbolKind.Method : vscode.SymbolKind.Function,
          toRange(s.range), toRange(s.selectionRange)));
      }
    }),

    vscode.languages.registerDocumentFormattingEditProvider(SEL, {
      async provideDocumentFormattingEdits(doc) {
        const r = await client.ask('textDocument/formatting', {
          textDocument: { uri: doc.uri.toString() }, options: { tabSize: 4, insertSpaces: true } });
        if (!r || !r.result) return [];
        return r.result.map((e) => vscode.TextEdit.replace(toRange(e.range), e.newText));
      }
    }),

    vscode.languages.registerCompletionItemProvider(SEL, {
      async provideCompletionItems(doc, pos) {
        const r = await client.ask('textDocument/completion', at(doc, pos));
        if (!r || !r.result) return [];
        return r.result.map((c) => {
          const item = new vscode.CompletionItem(c.label, c.kind === 14 ? vscode.CompletionItemKind.Keyword
                                                        : c.kind === 9  ? vscode.CompletionItemKind.Module
                                                        : c.kind === 6  ? vscode.CompletionItemKind.Variable
                                                        : c.kind === 21 ? vscode.CompletionItemKind.Constant
                                                        : vscode.CompletionItemKind.Function);
          if (c.detail) item.detail = c.detail;
          if (c.sortText) item.sortText = c.sortText;
          if (c.documentation) {
            item.documentation = typeof c.documentation === 'string'
              ? new vscode.MarkdownString(c.documentation)
              : new vscode.MarkdownString(c.documentation.value);
          }
          return item;
        });
      }
    }),

    vscode.languages.registerReferenceProvider(SEL, {
      async provideReferences(doc, pos) {
        const r = await client.ask('textDocument/references',
          Object.assign(at(doc, pos), { context: { includeDeclaration: true } }));
        if (!r || !r.result) return [];
        return r.result.map((l) => new vscode.Location(vscode.Uri.parse(l.uri), toRange(l.range)));
      }
    }),

    vscode.languages.registerRenameProvider(SEL, {
      // The server refuses to rename a builtin, a keyword or a name from a
      // module, and gives the reason. Throwing that reason here is how VS Code
      // shows it to the user before they type a new name.
      async prepareRename(doc, pos) {
        const r = await client.ask('textDocument/prepareRename', at(doc, pos));
        if (!r) throw new Error('word: the language server is not running.');
        if (r.error) throw new Error(r.error.message);
        if (!r.result) throw new Error('word: there is no name here to rename.');
        return toRange(r.result);
      },
      async provideRenameEdits(doc, pos, newName) {
        const r = await client.ask('textDocument/rename', Object.assign(at(doc, pos), { newName }));
        if (!r) return null;
        if (r.error) throw new Error(r.error.message);
        if (!r.result || !r.result.changes) return null;
        const edit = new vscode.WorkspaceEdit();
        for (const [uri, edits] of Object.entries(r.result.changes)) {
          for (const e of edits) edit.replace(vscode.Uri.parse(uri), toRange(e.range), e.newText);
        }
        return edit;
      }
    })
  );
}

module.exports = { activate, deactivate };
