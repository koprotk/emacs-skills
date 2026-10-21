---
name: emacsclient
description: 'Always use emacsclient instead of emacs. This applies to all Emacs operations: user requests, byte compilation, check-parens, running ERT tests, and any other elisp evaluation.'
tools: Bash
---

# Always use emacsclient

**Only applies when this session runs inside an Emacs agent-shell buffer.** Check once: `echo $INSIDE_EMACS` is not reliable, so instead run `emacsclient --eval '(and (fboundp (quote agent-shell-buffers)) (agent-shell-buffers) t)'`. If it fails or returns `nil`, ignore this skill and use normal tools (the plugin hook is inactive too).

The user has an Emacs server running. **All** Emacs operations must go through `emacsclient`, never `emacs` or `emacs --batch`. This includes both user-requested actions and agent-initiated operations like byte compilation, syntax checking, or running tests.

## Examples

- Open a file: `emacsclient --no-wait "/path/to/file"`
- Evaluate elisp: `emacsclient --eval '(some-function)'`
- Open at a line: `emacsclient --no-wait +42 "/path/to/file"`
- Byte compile a file:
  ```sh
  emacsclient --eval '
  (byte-compile-file "/path/to/file.el")'
  ```
- Check parentheses:
  ```sh
  emacsclient --eval '
  (with-temp-buffer
    (insert-file-contents "/path/to/file.el")
    (check-parens))'
  ```
- Run ERT tests:
  ```sh
  emacsclient --eval '
  (progn
    (load "/path/to/test-file.el" nil t)
    (ert-run-tests-batch-and-exit "pattern"))'
  ```

## Rules

- Always use `emacsclient`, never `emacs` or `emacs --batch`.
- Use `--no-wait` when opening files so the command returns immediately.
- Use `--eval` when evaluating elisp.
- Always format `--eval` elisp across multiple lines with proper indentation.
- Run `emacsclient` commands via the Bash tool.

## File edits

The plugin's `PreToolUse` hook already applies `Edit` and `Write` inside Emacs. When the hook reports "Applied inside Emacs", the change is saved; do not retry. Do not use `sed -i`, `tee`, or `>` redirects to modify files; they are denied.

## Content searches

The plugin's hook runs the Grep tool through ripgrep inside Emacs and returns the results in its message; do not retry. Do not use `rg`, `grep -r`, or `git grep` in Bash; they are denied.

## Reading, finding and symbol lookups

Keep source work inside Emacs/dedicated tools, not Bash text-munging. Do not use `grep`, `find`, `sed`, `awk`, `head` or `tail` in Bash to search, locate or read source (e.g. `grep -n X $(find src -name Foo.java) | head`, `sed -n '47,55p' Foo.java`). Instead:

- **Search text:** the Grep tool (routed through ripgrep in Emacs by the hook). Its `glob` option limits it to one file name (replaces `find`), and `head_limit` replaces `| head`.
- **Locate files:** the Glob tool.
- **Read a line range:** the Read tool with `offset`/`limit` (replaces `sed -n`).
- **Edit:** the Edit tool (replaces `sed -i`; it errors if the old text is not found, where `sed -i` fails silently).
- **Symbols (Java, etc.):** the LSP tool (`documentSymbol`, `workspaceSymbol`, `findReferences`, `goToDefinition`); the language server answers these more accurately than text matching.
- **Trimming a command's output:** filter inside Emacs when the tool offers it (e.g. `OUTPUT_GREP`/`OUTPUT_TAIL` in the `eglot-java-test` scripts) rather than piping through `grep`/`tail`.

The plugin hook currently denies only file-writing and recursive-grep Bash patterns; the rest of this section is guidance, not enforcement.
