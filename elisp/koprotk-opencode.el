;;; koprotk-opencode.el --- OpenCode entry points for hook-driven Emacs ops  -*- lexical-binding: t; -*-

;; OpenCode port of the Claude Code plugin.  The Claude hook calls
;; koprotk-edit-apply / koprotk-search-apply, which gate on agent-shell (an
;; agent-shell-mode ACP client process being an ancestor of the caller).
;; The OpenCode plugin (.opencode/plugins/emacs/index.ts) calls the entry
;; points here instead.  They gate on an explicit payload of
;; {client: "opencode", enabled: true}, which the plugin only sends after it
;; has verified that the Emacs server is reachable and that the
;; KOPROTK_EMACS_EDIT environment variable is not "off".
;;
;; The payload/result protocol and the actual edit/search work are shared with
;; the Claude path via koprotk-core.el, koprotk-edit.el and koprotk-search.el;
;; only the gate differs.

;;; Code:

(require 'koprotk-core)
(require 'koprotk-edit)
(require 'koprotk-search)

(declare-function koprotk-edit--dispatch "koprotk-edit")
(declare-function koprotk-search--dispatch "koprotk-search")

(defun koprotk-opencode--allowed (payload)
  "Non-nil when PAYLOAD is an authorized OpenCode request."
  (and (equal (alist-get 'client payload) "opencode")
       (eq (alist-get 'enabled payload) t)))

(defun koprotk-opencode-edit-apply (payload-file)
  "Apply the edit described in PAYLOAD-FILE (OpenCode client); write outcome."
  (koprotk-run payload-file #'koprotk-edit--dispatch #'koprotk-opencode--allowed))

(defun koprotk-opencode-search-apply (payload-file)
  "Run the search described in PAYLOAD-FILE (OpenCode client); write outcome."
  (koprotk-run payload-file #'koprotk-search--dispatch #'koprotk-opencode--allowed))

(provide 'koprotk-opencode)

;;; koprotk-opencode.el ends here
