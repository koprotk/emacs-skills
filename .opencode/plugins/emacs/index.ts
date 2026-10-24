import { Plugin } from "@opencode/plugin"
import { execFileSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, isAbsolute, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

/**
 * OpenCode port of the Claude Code plugin in this repository.  It routes the
 * `edit`, `write` and `grep` tools through a running Emacs server (emacsclient)
 * so that Eglot save hooks, formatters and the rest of your Emacs config apply
 * to agent changes.  It also blocks shell commands that would write files
 * behind Emacs' back (sed -i, perl -i, tee, redirects).
 *
 * The Emacs-side work is shared with the Claude path: this plugin drives the
 * same elisp files (elisp/koprotk-*.el) via a small JSON payload/result
 * protocol.  The only Claude-specific assumption in that elisp is the
 * agent-shell gate; the OpenCode entry points (koprotk-opencode-edit-apply /
 * -search-apply) replace it with an explicit {client:"opencode", enabled:true}
 * marker, which this plugin only sends when routing is turned on.
 *
 * Configuration:
 *   KOPROTK_EMACS_EDIT=off      disables routing entirely (native tools run)
 *   KOPROTK_EMACS_SOCKET=<name> targets a specific Emacs server socket
 *   KOPROTK_EMACS_ELISP_DIR=<p> overrides the location of the elisp files
 */

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(PLUGIN_DIR, "..", "..")
const ELISP_DIR = process.env.KOPROTK_EMACS_ELISP_DIR || join(REPO_ROOT, "elisp")
const ELISP_FILES = [
  "koprotk-core.el",
  "koprotk-edit.el",
  "koprotk-search.el",
  "koprotk-opencode.el",
].map((f) => join(ELISP_DIR, f))
const TIMEOUT_MS = 30_000

const SCRATCH_PREFIXES = ["/dev/", "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]

// Ordered longest-first so multi-char operators tokenize as single units.
const TOKEN_SPLIT = /(\s+|;|&&|\|\||\|&|&>>|&>|>>|>\||<<<|<<|<|\||&|>)/
const FILE_REDIRECTS = new Set([">", ">>", ">|", "&>", "&>>"])
const SEPARATORS = new Set([";", "&&", "||", "|", "|&", "&", "(", ")", "\n"])
const SKIP_REDIRECTS = new Set([">", ">>", ">|", "&>", "&>>", "<", "<<", "<<<"])

function disabled(): boolean {
  return process.env.KOPROTK_EMACS_EDIT === "off"
}

interface EmacsResult {
  ok?: boolean
  unreachable?: boolean
  agent_shell?: boolean
  error?: string
  message?: string
  save_diff?: string | null
  hook_errors?: string | null
  unsaved?: boolean
  output?: string
  note?: string
}

/** Run one elisp entry point through emacsclient, passing a JSON payload file. */
function emacsApply(payload: Record<string, unknown>, entry: string): EmacsResult {
  const tmp = mkdtempSync(join(tmpdir(), "koprotk-"))
  const payloadFile = join(tmp, "payload.json")
  const resultFile = join(tmp, "result.json")
  try {
    writeFileSync(payloadFile, JSON.stringify({ ...payload, result_file: resultFile }), "utf8")

    const args: string[] = []
    const socket = process.env.KOPROTK_EMACS_SOCKET
    if (socket) args.push("--socket-name", socket)
    const loads = ELISP_FILES.map((f) => `(load ${JSON.stringify(f)} nil t)`).join(" ")
    args.push("--eval", `(progn ${loads} (${entry} ${JSON.stringify(payloadFile)}))`)

    let stdout = ""
    let stderr = ""
    try {
      stdout = execFileSync("emacsclient", args, { encoding: "utf8", timeout: TIMEOUT_MS })
    } catch (err: any) {
      if (err?.code === "ENOENT") {
        return { ok: false, unreachable: true, error: "emacsclient not found in PATH" }
      }
      if (err?.killed || err?.signal) {
        return { ok: false, unreachable: true, error: `emacsclient timed out after ${TIMEOUT_MS / 1000}s; Emacs may be blocked on a prompt` }
      }
      stdout = err?.stdout ?? ""
      stderr = err?.stderr ?? ""
    }

    if (!existsSync(resultFile)) {
      const detail = (stderr || stdout).trim()
      return { ok: false, unreachable: true, error: `Emacs did not apply the operation (is the server running? M-x server-start): ${detail}` }
    }
    return JSON.parse(readFileSync(resultFile, "utf8")) as EmacsResult
  } finally {
    try {
      rmSync(tmp, { recursive: true, force: true })
    } catch {
      /* ignore cleanup failures */
    }
  }
}

function resolvePath(p: string, dir: string): string {
  return isAbsolute(p) ? p : resolve(dir, p)
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

/** Build the message returned to the model for a routed edit/write. */
function editMessage(file: string, result: EmacsResult): string {
  let msg = `Applied inside Emacs via emacsclient: ${result.message}. The native tool was skipped on purpose; the change is already saved to ${file}. Do not retry.`
  if (result.save_diff) {
    msg += `\n\nWARNING: Emacs save hooks (formatter, LSP fixes, etc.) changed the text while saving, so the file differs from what you wrote. Diff (your text -> saved text):\n${result.save_diff}\n\nRe-read the file before editing it again.`
  }
  if (result.hook_errors) {
    msg += `\n\nWARNING: Emacs save hooks raised errors (the file was still saved, but those hooks, e.g. LSP fixes or formatting, did not complete):\n${result.hook_errors}`
  }
  if (result.unsaved) {
    msg += `\n\nWARNING: the Emacs buffer still has unsaved changes after saving (an after-save hook modified it). Check the buffer before further edits.`
  }
  return msg
}

function isScratch(target: string): boolean {
  const tmpdirEnv = process.env.TMPDIR ?? ""
  return SCRATCH_PREFIXES.some((p) => target.startsWith(p)) || (tmpdirEnv !== "" && target.startsWith(tmpdirEnv))
}

/** Port of hooks/route-edits.py's `bash_block_reason`, restricted to file writes. */
function fileWriteReason(command: string): string | null {
  const tokens = command.split(TOKEN_SPLIT).filter((t) => t.trim() !== "")

  // redirects to non-scratch targets (skip `>&`/`2>&1` fd duplication)
  for (let i = 0; i < tokens.length; i++) {
    if (!FILE_REDIRECTS.has(tokens[i])) continue
    const target = tokens[i + 1]
    if (!target || target === "&") continue
    if (!isScratch(target)) return `output redirect to ${target}`
  }

  const commands: string[][] = []
  let current: string[] = []
  for (const tok of tokens) {
    if (SEPARATORS.has(tok)) {
      if (current.length) commands.push(current)
      current = []
    } else {
      current.push(tok)
    }
  }
  if (current.length) commands.push(current)

  for (const words of commands) {
    const clean: string[] = []
    let skip = false
    for (const w of words) {
      if (skip) {
        skip = false
        continue
      }
      if (SKIP_REDIRECTS.has(w)) {
        skip = true
        continue
      }
      clean.push(w)
    }
    while (clean.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(clean[0])) clean.shift()
    if (!clean.length) continue

    const name = clean[0].split("/").pop()!
    const args = clean.slice(1)

    if (name === "sed" && args.some((a) => /^-[a-zA-Z]*i/.test(a) || a.startsWith("--in-place"))) return "sed -i"
    if ((name === "perl" || name === "ruby") && args.some((a) => /^-[a-hj-zA-Z]*i/.test(a) && !a.startsWith("-M") && !a.startsWith("-m"))) return `${name} -i`
    if (name === "tee") {
      const targets = args.filter((a) => !a.startsWith("-"))
      if (targets.some((t) => !isScratch(t))) return "tee to a file"
    }
  }
  return null
}

export default Plugin.define({
  id: "emacs",
  async setup(ctx) {
    const dirCache = new Map<string, string>()

    async function sessionDir(sessionID: string): Promise<string> {
      const cached = dirCache.get(sessionID)
      if (cached) return cached
      let dir = ctx.location.directory
      try {
        const session = await ctx.session.get({ sessionID })
        dir = session.location.directory
      } catch {
        /* fall back to the plugin location directory */
      }
      dirCache.set(sessionID, dir)
      return dir
    }

    async function routeEdit(input: any, context: any, original: Function): Promise<any> {
      const dir = await sessionDir(context.sessionID)
      const file = resolvePath(input.path, dir)
      const payload = {
        op: "edit",
        file,
        old: input.oldString ?? "",
        new: input.newString ?? "",
        replace_all: input.replaceAll === true,
        client: "opencode",
        enabled: true,
      }
      const result = emacsApply(payload, "koprotk-opencode-edit-apply")
      if (result.unreachable || (result.ok === true && result.agent_shell !== true)) {
        return original(input, context)
      }
      if (result.ok !== true) {
        throw new Error(`edit failed in Emacs: ${result.error}`)
      }
      return { content: editMessage(file, result) }
    }

    async function routeWrite(input: any, context: any, original: Function): Promise<any> {
      const dir = await sessionDir(context.sessionID)
      const file = resolvePath(input.path, dir)
      const payload = { op: "write", file, content: input.content ?? "", client: "opencode", enabled: true }
      const result = emacsApply(payload, "koprotk-opencode-edit-apply")
      if (result.unreachable || (result.ok === true && result.agent_shell !== true)) {
        return original(input, context)
      }
      if (result.ok !== true) {
        throw new Error(`write failed in Emacs: ${result.error}`)
      }
      return { content: editMessage(file, result) }
    }

    async function routeGrep(input: any, context: any, original: Function): Promise<any> {
      const dir = await sessionDir(context.sessionID)
      const pattern = input.literal === true ? escapeRegex(input.pattern) : input.pattern
      const payload = {
        cwd: dir,
        pattern,
        path: input.path ? resolvePath(input.path, dir) : dir,
        glob: input.include ?? null,
        mode: "content",
        ignore_case: input.caseSensitive === false,
        line_numbers: true,
        head_limit: input.limit ?? null,
        client: "opencode",
        enabled: true,
      }
      const result = emacsApply(payload, "koprotk-opencode-search-apply")
      if (result.unreachable || (result.ok === true && result.agent_shell !== true)) {
        return original(input, context)
      }
      if (result.ok !== true) {
        throw new Error(`grep failed in Emacs: ${result.error}`)
      }
      let out = `Search ran inside Emacs (ripgrep). The native grep was skipped on purpose; these are its results, do not retry:\n\n${result.output ?? ""}`
      if (result.note) out += `\n\n${result.note}`
      return { content: out }
    }

    const toolRegistration = await ctx.tool.transform((editor) => {
      const wrap = (id: string, run: (input: any, context: any, original: Function) => Promise<any>) => {
        editor.update(id, (tool: any) => {
          const original = tool.execute
          tool.execute = async (input: any, context: any) => {
            if (disabled()) return original(input, context)
            return run(input, context, original)
          }
        })
      }
      wrap("edit", routeEdit)
      wrap("write", routeWrite)
      wrap("grep", routeGrep)
    })

    const shellRegistration = await ctx.shell.hook("create.before", (event) => {
      if (disabled()) return
      const reason = fileWriteReason(event.command)
      if (!reason) return
      throw new Error(
        `Shell file edits are routed through Emacs (detected: ${reason}). ` +
          `Use the Edit or Write tool (applied in Emacs via emacsclient), or emacsclient --eval. ` +
          `Redirecting to /tmp is allowed for scratch output.`,
      )
    })

    return async () => {
      await toolRegistration.dispose()
      await shellRegistration.dispose()
    }
  },
})
