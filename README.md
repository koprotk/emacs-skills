# koprotk-emacs-skill

Claude Code plugin that routes file edits and content searches through a running Emacs server, so your Eglot save hooks (LSP fixes, indentation) and the rest of your Emacs config apply to agent changes.

This is a personal plugin. The name only exists to tell it apart from xenodium's `emacs-skills`.

## Requirements

- A running Emacs server (`M-x server-start`) and `emacsclient` on `PATH`.
- Emacs 27+ (uses `json-parse-string`; developed against Emacs 30).
- `rg` (ripgrep) on Emacs' `exec-path`.
- `python3` for the hook script.

## Install

Install through the repo's local marketplace (works for sessions launched by agent-shell, which cannot pass `--plugin-dir`):

```sh
claude plugin marketplace add /path/to/this/repo
claude plugin install koprotk-emacs-skill@koprotk
```

Restart the agent-shell session afterwards. If the upstream `emacs-skills` plugin is also installed, disable it to avoid a duplicate `emacsclient` skill.

For a one-off terminal session you can instead load it directly:

```sh
claude --plugin-dir /path/to/this/repo
```

The plugin manifest is `.claude-plugin/plugin.json`; the marketplace manifest is `.claude-plugin/marketplace.json`.

## agent-shell only

The plugin acts only when Claude Code was launched by an [agent-shell](https://github.com/xenodium/agent-shell) buffer in the Emacs server. The hook sends the pids of its own ancestors to Emacs; Emacs checks whether the ACP client process of any live `agent-shell-mode` buffer is among them. If not (terminal Claude, vterm, no Emacs server), the hook does nothing and the native Edit/Write/Grep/Bash run normally. Bash commands are only checked against Emacs when they would be blocked, so ordinary commands cost nothing.

## What it does

A single `PreToolUse` hook (`hooks/route-edits.py`) intercepts `Edit`, `Write`, `Grep` and `Bash`, and performs the work inside Emacs through `emacsclient`. The native tool call is then skipped and the result is returned to the agent in the hook's message.

### Edits and saves

- **Edit / Write** are applied in the file's Emacs buffer (`elisp/koprotk-edit.el`) and saved with `save-buffer`. Undo history and open buffers behave as if you made the edit yourself.
- **Save hooks run.** Your `before-save-hook` / `after-save-hook` (formatters, Eglot code actions such as `source.fixAll`) fire on every agent edit. The plugin ships none of them; add them in your own config.
- **The agent is told what saving changed.** If hooks rewrote the text, it receives a diff (its text to the saved text). If a hook raised an error, it receives the message, since Emacs demotes those errors and saves anyway.
- **Failed saves roll back** the edit, so a broken save never leaves a modified buffer behind.
- **Unsaved changes are protected.** If the target buffer has unsaved changes, or is read-only, the edit is refused with a message. A buffer whose file changed on disk is reverted before the edit.
- **No hangs.** Emacs questions during an edit (`yes-or-no-p`, `y-or-n-p`) become errors instead of blocking the server.

### Searches

- **Grep** runs ripgrep from inside Emacs (`elisp/koprotk-search.el`), so it uses your `exec-path` and respects `.gitignore`. All output modes and the `-i`, `-A/-B/-C`, `glob`, `type`, `multiline`, `head_limit` and `offset` options are supported.
- **Scope** is the directory Claude Code was launched in, or the `path` the Grep call passes. It is not tied to an Emacs project (`project.el`) or your current buffer.
- ripgrep is run directly rather than through `xref-matches-in-directory`, because xref would translate the agent's Rust regexes as Emacs regexps.
- Set `koprotk-search-show-results` to `t` to also show hits in an xref buffer (displayed without taking focus).

### Bash guard

Shell commands that bypass Emacs are denied with a pointer to the right tool:

- **File writes**: `sed -i`, `perl -i`, `tee`, and `>` / `>>` redirects. Scratch targets (`/dev/`, `/tmp/`, `$TMPDIR`) are allowed.
- **Content searches**: `rg`, `grep -r`, `git grep`, `find | xargs grep`. Plain `grep` in a pipe and `rg --files` are untouched.

## Skills

### emacsclient (auto)

Always prefer `emacsclient` over `emacs` when the agent needs to interact with Emacs. Not a slash command; it activates automatically. It also tells the agent how the hook behaves so it does not retry a routed call.

## Configuration

| Setting | Where | Effect |
| :- | :- | :- |
| `KOPROTK_EMACS_EDIT=off` | environment | Disables the hook entirely |
| `KOPROTK_EMACS_SOCKET` | environment | Targets a specific Emacs server socket |
| `koprotk-search-show-results` | Emacs variable | Also show Grep hits in an xref buffer |

If Emacs is not reachable, the hook cannot verify agent-shell and falls back to the native tools.

## Eglot

Starting Eglot is your config's job. `eglot-ensure` waits for a command to run in the buffer, and a buffer the hook opens in the background never gets one. Connect from a hook that fires on file open (for example `(eglot)` in the mode hook) if you want LSP fixes to apply on the first edit of a file you have not opened.

## Layout

```
.claude-plugin/plugin.json   plugin manifest
.claude-plugin/marketplace.json  local marketplace manifest
hooks/hooks.json             registers the PreToolUse hook
hooks/route-edits.py         hook: routing, Bash guard
elisp/koprotk-core.el        JSON payload/result protocol, prompt handling
elisp/koprotk-edit.el        edit + save in the file's buffer
elisp/koprotk-search.el      ripgrep from Emacs
skills/emacsclient/SKILL.md  guidance skill
```

## Known limits

- `NotebookEdit` and `Glob` are not routed.
- Scripted file writes or searches (`python -c`, `node -e`) cannot be detected.
- Bash detection is heuristic, so unusual commands can slip through or be flagged.
- Edited files stay open as buffers in your Emacs.
