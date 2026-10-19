# koprotk-emacs-skill

Claude Code plugin that routes file edits and content searches through a running Emacs server, so your Eglot save hooks (LSP fixes, indentation) and Emacs config apply to agent changes.

Load it locally: `claude --plugin-dir /path/to/this/repo`. Requires a running Emacs server (`M-x server-start`) and `rg` on the Emacs `exec-path`.

## Skills

### emacsclient (auto)

Always prefer `emacsclient` over `emacs` when the agent needs to interact with Emacs. This skill is not a slash command; it activates automatically.

## Hooks

### Edits and searches inside Emacs (auto)

`hooks/route-edits.py` is a `PreToolUse` hook that routes file edits and content searches through the running Emacs server instead of touching the filesystem directly.

- **Edit / Write**: applied in the file's Emacs buffer via `emacsclient` (`elisp/koprotk-edit.el`), saved, and the native tool call is skipped. Undo history, open buffers, and save hooks all behave as if you made the edit yourself.
- **Bash**: commands that write files (`sed -i`, `perl -i`, `tee`, `>` / `>>` redirects) are denied with a pointer to the Emacs path. Scratch targets (`/dev/`, `/tmp/`, `$TMPDIR`) are allowed.
- **Grep**: ripgrep runs from inside Emacs (`elisp/koprotk-search.el`, so it uses your `exec-path` and respects `.gitignore`), and the hits are returned to the agent. Bash content searches (`rg`, `grep -r`, `git grep`, `find | xargs grep`) are denied with a pointer to the Grep tool; plain `grep` in a pipe is untouched. Set `koprotk-search-show-results` to `t` to also show hits in an xref buffer. ripgrep is run directly, not through `xref-matches-in-directory`, because xref would translate the agent's Rust regexes as Emacs regexps.
- **Safety**: if the target buffer has unsaved changes, the edit is refused instead of clobbering them. Buffers whose file changed on disk are reverted first.
- **Save hooks**: saving uses Emacs' own `save-buffer`, so your `before-save-hook` / `after-save-hook` run (formatters, LSP code actions, etc.). The plugin ships none of these; add them in your own config. If hooks change the text, or raise errors (Emacs demotes them and saves anyway), the agent gets a diff or the error message. A failed save rolls the edit back.
- **Prompts**: Emacs questions during an edit (`yes-or-no-p`, `y-or-n-p`) become errors instead of hanging the server.
- **Emacs down**: edits fail with a message to start the server (`M-x server-start`).

Environment variables: `KOPROTK_EMACS_EDIT=off` disables the hook; `KOPROTK_EMACS_SOCKET` targets a specific server socket.

Known limits: `NotebookEdit` is not routed, and scripting-language file writes (`python -c`, `node -e`) can't be detected.
