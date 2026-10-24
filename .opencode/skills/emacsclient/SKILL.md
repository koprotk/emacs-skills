---
name: emacsclient
description: Always use emacsclient instead of emacs for all Emacs operations: opening files, evaluating elisp, byte compilation, syntax checking, running tests.
---

# Always use emacsclient

The user has an Emacs server running. **All** Emacs operations must go through `emacsclient`, never `emacs` or `emacs --batch`. This includes both user-requested actions and agent-initiated operations like byte compilation, syntax checking, or running tests.

Verify the server once: `emacsclient --eval t`. If it fails ("can't find socket"), the server is not running and this skill does not apply (the plugin hook is inactive too).

## Examples

- Open a file: `emacsclient --no-wait "/path/to/file"`
- Evaluate elisp: `emacsclient --eval '(some-function)'`
- Open at a line: `emacsclient --no-wait +42 "/path/to/file"`
- Byte compile a file:
  ```sh
  emacsclient --eval '(byte-compile-file "/path/to/file.el")'
  ```
- Check parentheses:
  ```sh
  emacsclient --eval '(with-temp-buffer (insert-file-contents "/path/to/file.el") (check-parens))'
  ```

## Rules

- Always use `emacsclient`, never `emacs` or `emacs --batch`.
- Use `--no-wait` when opening files so the command returns immediately.
- Use `--eval` when evaluating elisp.
- Run `emacsclient` commands via the shell tool.

## File edits are routed through Emacs

The plugin applies the `edit` and `write` tools inside Emacs (through `emacsclient`), so your `before-save-hook` / `after-save-hook` (formatters, Eglot code actions such as `source.fixAll`) fire on every agent edit. When a tool result says "Applied inside Emacs", the change is already saved — do not retry.

Do not use `sed -i`, `perl -i`, `tee`, or `>` / `>>` redirects to modify files; they are blocked. Redirecting to `/tmp` is allowed for scratch output.

## Reading, finding and searching

Keep source work inside dedicated tools, not shell text-munging. Do not use `cat`, `grep`, `find`, `sed`, `awk`, `head` or `tail` in the shell to search, locate or read source:

- **Search text:** the `grep` tool (routed through ripgrep in Emacs by the plugin when available). Its `include` option limits it to one file pattern (replaces `find`).
- **Locate files:** the `glob` tool.
- **Read a file:** the `read` tool (replaces `cat`).
- **Edit:** the `edit` tool (it errors if the old text is not found, where `sed -i` fails silently).
- **Symbols (Java, etc.):** the LSP tool (`documentSymbol`, `workspaceSymbol`, `findReferences`, `goToDefinition`).

> Note: some models may not be given the `grep`/`glob` tools by OpenCode and will instead use `rg`/`find` in the shell. That is acceptable — a shell search still runs with the correct `PATH` and `.gitignore`; it just does not run inside Emacs. Prefer `grep`/`glob` when they are available.
