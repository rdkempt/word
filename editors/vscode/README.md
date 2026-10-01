# word for VS Code

This folder is a VS Code extension that gives `.w` files highlighting, diagnostics,
go-to-definition, formatting, an outline, hover, completion, references and rename.

There's nothing to build: no `npm install`, no build step, no dependencies. VS Code already ships
Node, and both halves of this are plain Node. To use it, start VS Code with the folder loaded as a
development extension:

```sh
code --extensionDevelopmentPath=/path/to/editors/vscode /path/to/your/project
```

Opening the folder in VS Code and pressing F5 starts an Extension Development Host with it loaded
the same way. Copying the folder into `~/.vscode/extensions/` (`%USERPROFILE%\.vscode\extensions`
on Windows) only works while that folder has no `extensions.json`, which is to say before you've
installed any other extension. When I tried it with VS Code 1.136, only the extensions named in that
file were loaded, and a folder dropped in beside them was ignored.

## What it does, and who decides

| | |
|---|---|
| **Diagnostics** | `word build -asm` on the unsaved buffer, 200 ms after you stop typing |
| **Format Document** | `word format`, the one canonical layout (SPEC §2.2) |
| **Go to Definition** | functions across the folder, locals and parameters in scope |
| **Hover** | signature and doc comment; SPEC prose for builtins and module functions |
| **Outline / breadcrumbs** | every function and `:before`/`:after` hook |
| **Rename** | a function across the whole program, a local inside its own function |
| **References** | the same occurrences, without editing them |
| **Completion** | locals, folder functions, builtins, module functions, keywords |
| **Highlighting** | the TextMate grammar, which needs none of the above |

The server never decides anything the compiler already decides. A diagnostic is the compiler's own
message from stderr, parsed and placed. A format is `word format`'s own output. The builtin and
module tables are generated out of `compiler/word.w`. What the server works out itself is only what a
compiler has no reason to expose: where a name is defined, what's in scope at a point, and which
occurrences a rename may touch.

A server that carries its own parser drifts away from the compiler and then underlines correct code
with confidence, and that's the kind people turn off. This one can be wrong about an outline, but an
error it shows is always the compiler's.

It follows the folder model of SPEC §11, because the compiler does. In a directory holding an
`app.w`, every `.w` file there is one program, so a call to a function defined in a sibling resolves,
and an error in that sibling is reported in the sibling. A `.w` file in a directory without an
`app.w` builds alone, so a scratch directory of unrelated `.w` files pulls in nothing it didn't name.

Diagnostics come from the buffer, not the file on disk. The folder is mirrored to a temp directory
with the unsaved text substituted, including the directory listing, since that's what the folder
glob reads. The server never writes to your files: Format Document hands the editor an edit, the
same as typing it.

### What rename refuses, and what it doesn't

A rename is refused when the name isn't the program's to rename (`out`, `if`, `true`, `read`), and
the server says why. But SPEC §2.5 says builtins are ordinary identifiers that a program may
shadow, and when it does, the program's definition wins: a `len(x)` you wrote is yours, and you can
rename it. `result` is contextual in the same way (SPEC §2.4): it means something only inside an
`:after` hook, and it's an ordinary name everywhere else. So the question the server asks is "does
this program bind this name here", not "is this name also a builtin", because the first one is the
language's rule.

Renaming *onto* a builtin is a different question, and it's refused. It would be legal (the program
would shadow the builtin), but nobody renames something to change what every existing call to `len`
does.

## Finding the compiler

Diagnostics and formatting come from the compiler, so the server has to find it. It tries, in order:
`word.compilerPath` in your settings, `$WORD_BIN`, `./word` (`word.exe` on Windows) in the workspace
root (a checkout builds its own), then `word` on `PATH`. If none of those exist it tells you once,
so a missing compiler doesn't look like a program with no mistakes in it.

## Other editors

`server.js` is an ordinary LSP server over stdio and knows nothing about VS Code. `extension.js` is
the adapter, and it's the only file here that does. Point any client at the server:

```sh
node /path/to/editors/vscode/server.js --stdio
```

`--stdio` is accepted and ignored, since most clients pass it anyway, and `--word <path>` names the
compiler. Neovim, for instance:

```lua
vim.lsp.start({
  name = 'word',
  cmd = { 'node', '/path/to/editors/vscode/server.js', '--stdio' },
  root_dir = vim.fs.dirname(vim.fs.find({ 'app.w' }, { upward = true })[1]),
})
```

It lives under `vscode/` so the folder stays a working VS Code extension. If a second editor ever
wants an adapter of its own, that's when the server moves up a level.

## Generated files

`word.tmLanguage.json` and `langdata.json` are generated by `dev/toolchain/gen_tmgrammar.sh` and
`dev/toolchain/gen_lspdata.sh`. The names come from `compiler/word.w` (the builtins out of
`builtin_arity`, the module names out of `is_module_name`, the module functions out of
`add_module_funcs`), and the prose comes from SPEC.md's own builtin tables.

A keyword list kept by hand goes stale the first time the language gains a builtin, and an editor is
the last place anyone looks for it. `dev/toolchain/test_tmgrammar.sh` and
`dev/toolchain/test_langserver.sh` fail if either committed file no longer matches what its
generator produces. Because the names and the prose come from two places, they can disagree, and the
test fails on that too, so a builtin the compiler has and the SPEC doesn't is caught as a
documentation bug.

The five keywords (`if else loop return break`) and the contextual words (`before`, `after`,
`result`, `import`, `in`) are written into the generators by hand, since SPEC §2.4 fixes them.

## Tests

```sh
sh dev/toolchain/test_langserver.sh
```

It regenerates the tables and diffs them, and checks that the compiler and the SPEC agree on every
name. Then it drives the server over real LSP framing and makes 53 checks: an unsaved edit is what
gets compiled, a diagnostic lands on the right identifier, a rename of a parameter doesn't escape its
function, `import` offers exactly the closed module list, and so on, and last, that an error typed
into `compiler/word.w` is found from the buffer. Finally it checks the server's scanner against an
oracle the compiler gives for free: every function becomes an `fn_<name>:` label in `word build -asm`
output, so the outline of every program in the repo (58 of them today) is compared with the
compiler's own list of its functions.
