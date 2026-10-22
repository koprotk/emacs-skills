#!/usr/bin/env python3
"""PreToolUse hook: route file edits and content searches through Emacs.

- Edit/Write: applied inside the running Emacs via emacsclient, then the
  native tool call is denied (the change is already on disk).
- Grep: ripgrep runs inside Emacs (elisp/koprotk-search.el); results are
  returned in the denial message. Bash content searches (rg, grep -r,
  git grep) are denied with a pointer to the Grep tool.
- Bash: commands that write files (sed -i, perl -i, tee, > redirects) are
  denied with a pointer to the Emacs path. `find` is denied with a pointer
  to the Glob tool.

Everything is gated on agent-shell: the hook only acts when Claude Code was
launched by an agent-shell buffer of the Emacs server (an agent-shell ACP
client process is an ancestor of the hook). Otherwise it does nothing and
the native tools run.

Set KOPROTK_EMACS_EDIT=off to disable. Set KOPROTK_EMACS_SOCKET to target a
specific Emacs server socket.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ELISP_FILES = [os.path.join(PLUGIN_ROOT, "elisp", f)
               for f in ("koprotk-core.el", "koprotk-edit.el", "koprotk-search.el")]
TIMEOUT = 30

SCRATCH_PREFIXES = ("/dev/", "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")
SEPARATORS = {";", "&&", "||", "|", "|&", "&", "(", ")", "\n"}
REDIRECTS = {">", ">>", ">|", "&>", "&>>"}


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def elisp_string(s):
    return json.dumps(s, ensure_ascii=False)


def emacs_apply(payload, entry="koprotk-edit-apply"):
    with tempfile.TemporaryDirectory(prefix="koprotk-") as tmp:
        payload_file = os.path.join(tmp, "payload.json")
        result_file = os.path.join(tmp, "result.json")
        with open(payload_file, "w", encoding="utf-8") as f:
            json.dump({**payload, "result_file": result_file, "ancestor_pids": ancestor_pids()}, f, ensure_ascii=False)

        cmd = ["emacsclient"]
        socket = os.environ.get("KOPROTK_EMACS_SOCKET")
        if socket:
            cmd += ["--socket-name", socket]
        loads = " ".join(f"(load {elisp_string(f)} nil t)" for f in ELISP_FILES)
        cmd += ["--eval", f"(progn {loads} ({entry} {elisp_string(payload_file)}))"]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
        except FileNotFoundError:
            return {"ok": False, "unreachable": True, "error": "emacsclient not found in PATH"}
        except subprocess.TimeoutExpired:
            return {"ok": False, "unreachable": True,
                    "error": f"emacsclient timed out after {TIMEOUT}s; Emacs may be blocked on a prompt"}
        if not os.path.exists(result_file):
            detail = (proc.stderr or proc.stdout).strip()
            return {"ok": False, "unreachable": True,
                    "error": f"Emacs did not apply the edit (is the server running? M-x server-start): {detail}"}
        with open(result_file, encoding="utf-8") as f:
            return json.load(f)


def ancestor_pids():
    """Pids of this process's ancestors (parent, grandparent, ...)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    parents = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and all(p.isdigit() for p in parts):
            parents[int(parts[0])] = int(parts[1])
    pids, pid = [], os.getppid()
    while pid > 1 and pid not in pids:
        pids.append(pid)
        pid = parents.get(pid, 0)
    return pids


def in_agent_shell():
    """True if Emacs confirms an agent-shell buffer launched this session."""
    result = emacs_apply({}, "koprotk-gate-apply")
    return bool(result.get("ok") and result.get("agent_shell"))


def resolve(path, cwd):
    path = os.path.expanduser(path)
    return path if os.path.isabs(path) else os.path.join(cwd, path)


def route_edit(tool, tool_input, cwd):
    file = resolve(tool_input.get("file_path", ""), cwd)
    if tool == "Edit":
        payload = {
            "op": "edit",
            "file": file,
            "old": tool_input.get("old_string", ""),
            "new": tool_input.get("new_string", ""),
            "replace_all": bool(tool_input.get("replace_all")),
        }
    else:
        payload = {"op": "write", "file": file, "content": tool_input.get("content", "")}

    result = emacs_apply(payload)
    if result.get("unreachable") or (result.get("ok") and not result.get("agent_shell")):
        return  # no Emacs, or not under agent-shell: let the native tool run
    if result.get("ok"):
        reason = (f"Applied inside Emacs via emacsclient: {result.get('message')}. "
                  f"The native {tool} call was skipped on purpose; the change is already saved "
                  f"to {file}. Do not retry.")
        if result.get("save_diff"):
            reason += ("\n\nWARNING: Emacs save hooks (formatter, LSP fixes, etc.) changed the "
                       "text while saving, so the file differs from what you wrote. Diff "
                       "(your text -> saved text):\n" + result["save_diff"] +
                       "\n\nRe-read the file before editing it again.")
        if result.get("hook_errors"):
            reason += ("\n\nWARNING: Emacs save hooks raised errors (the file was still saved, "
                       "but those hooks, e.g. LSP fixes or formatting, did not complete):\n"
                       + result["hook_errors"])
        if result.get("unsaved"):
            reason += ("\n\nWARNING: the Emacs buffer still has unsaved changes after saving "
                       "(an after-save hook modified it). Check the buffer before further edits.")
        deny(reason)
    deny(f"{tool} failed in Emacs: {result.get('error')}")


def route_search(tool_input, cwd):
    payload = {
        "cwd": cwd,
        "pattern": tool_input.get("pattern", ""),
        "path": resolve(tool_input["path"], cwd) if tool_input.get("path") else cwd,
        "glob": tool_input.get("glob"),
        "type": tool_input.get("type"),
        "mode": tool_input.get("output_mode") or "files_with_matches",
        "ignore_case": bool(tool_input.get("-i")),
        "line_numbers": tool_input.get("-n", True) is not False,
        "after": tool_input.get("-A"),
        "before": tool_input.get("-B"),
        "context": tool_input.get("-C") if tool_input.get("-C") is not None else tool_input.get("context"),
        "multiline": bool(tool_input.get("multiline")),
        "head_limit": tool_input.get("head_limit"),
        "offset": tool_input.get("offset"),
    }
    result = emacs_apply(payload, "koprotk-search-apply")
    if result.get("unreachable") or (result.get("ok") and not result.get("agent_shell")):
        return
    if not result.get("ok"):
        deny(f"Grep failed in Emacs: {result.get('error')}")
    reason = ("Search ran inside Emacs (ripgrep). The native Grep call was skipped on purpose; "
              "these are its results, do not retry:\n\n" + result.get("output", ""))
    if result.get("note"):
        reason += "\n\n" + result["note"]
    deny(reason)


def is_scratch(target):
    tmpdir = os.environ.get("TMPDIR", "")
    return target.startswith(SCRATCH_PREFIXES) or bool(tmpdir and target.startswith(tmpdir))


def tokenize(command):
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    tokens = []
    try:
        for tok in lex:
            tokens.append(tok)
    except ValueError:
        pass  # unbalanced quotes (e.g. heredoc body): analyse what we have
    return strip_heredoc_bodies(tokens)


def strip_heredoc_bodies(tokens):
    """Drop heredoc bodies: text after `<< DELIM` up to the line `DELIM`."""
    out, i = [], 0
    while i < len(tokens):
        out.append(tokens[i])
        if tokens[i] in {"<<", "<<-"} and i + 1 < len(tokens):
            delim = tokens[i + 1]
            out.append(delim)
            i += 2
            while i < len(tokens) and "\n" not in tokens[i]:  # rest of the command line
                out.append(tokens[i])
                i += 1
            while i < len(tokens) and tokens[i] != delim:  # the body
                i += 1
            i += 1
            continue
        i += 1
    return out


def split_commands(tokens):
    commands, current = [], []
    for tok in tokens:
        if tok in SEPARATORS or (tok and set(tok) <= set(";&|()\n") and tok not in REDIRECTS):
            if current:
                commands.append(current)
            current = []
        else:
            current.append(tok)
    if current:
        commands.append(current)
    return commands


def bash_block_reason(command):
    tokens = tokenize(command)

    for i, tok in enumerate(tokens):
        if tok in REDIRECTS and i + 1 < len(tokens):
            target = tokens[i + 1]
            if not is_scratch(target):
                return f"output redirect to {target}"

    for words in split_commands(tokens):
        # drop redirect operators with their targets, and leading VAR=value
        clean, skip = [], False
        for w in words:
            if skip:
                skip = False
            elif w in REDIRECTS or w in {"<", "<<", "<<<", ">&"}:
                skip = True
            else:
                clean.append(w)
        while clean and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", clean[0]):
            clean.pop(0)
        if not clean:
            continue
        name, args = os.path.basename(clean[0]), clean[1:]

        if name == "sed" and any(re.match(r"^-[a-zA-Z]*i", a) or a.startswith("--in-place") for a in args):
            return "sed -i"
        if name in {"perl", "ruby"} and any(
                re.match(r"^-[a-hj-zA-Z]*i", a) and not a.startswith(("-M", "-m")) for a in args):
            return f"{name} -i"
        if name in {"rg", "ag", "ack"} and "--files" not in args:
            return f"content search with {name}"
        if name == "git" and args[:1] == ["grep"]:
            return "git grep"
        if name in {"grep", "egrep", "fgrep"} and any(
                re.match(r"^-[a-zA-Z]*[rR]", a) or a.startswith(("--recursive", "--include", "--exclude"))
                for a in args):
            return f"recursive {name}"
        if name in {"find", "xargs"} and any(os.path.basename(a) in {"grep", "egrep", "fgrep", "rg"} for a in args):
            return f"{name} piped into grep"
        if name == "find":
            return "file lookup with find"
        if name == "tee":
            targets = [a for a in args if not a.startswith("-")]
            if any(not is_scratch(t) for t in targets):
                return "tee to a file"
    return None


def main():
    if os.environ.get("KOPROTK_EMACS_EDIT") == "off":
        return
    data = json.load(sys.stdin)
    tool = data.get("tool_name")
    tool_input = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()

    if tool in {"Edit", "Write"}:
        route_edit(tool, tool_input, cwd)
    elif tool == "Grep":
        route_search(tool_input, cwd)
    elif tool == "Bash":
        reason = bash_block_reason(tool_input.get("command", ""))
        if reason and in_agent_shell():
            if reason == "file lookup with find":
                deny("File lookups are routed through Emacs-aware tools (detected: find). "
                     "Use the Glob tool to locate files by name; use Grep with `glob` to "
                     "search inside them.")
            if "search" in reason or "grep" in reason:
                deny(f"Content searches are routed through Emacs (detected: {reason}). "
                     "Use the Grep tool; it runs ripgrep inside Emacs.")
            deny(f"Shell file edits are routed through Emacs (detected: {reason}). "
                 "Use the Edit or Write tool (applied in Emacs via emacsclient), or "
                 "emacsclient --eval. Redirecting to /tmp is allowed for scratch output.")


if __name__ == "__main__":
    main()
