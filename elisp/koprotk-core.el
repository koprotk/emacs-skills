;;; koprotk-core.el --- Shared plumbing for hook-driven Emacs operations  -*- lexical-binding: t; -*-

;; The hooks (hooks/route-edits.py) call Emacs through emacsclient.  Each call
;; passes a JSON payload file; the operation's result is written as JSON to
;; the payload's result_file so no output parsing is needed.

;;; Code:

(require 'cl-lib)
(require 'json)

(defun koprotk--read-json (file)
  "Parse FILE as JSON into an alist (arrays become lists, false and null become nil)."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (goto-char (point-min))
    (json-parse-string (buffer-string)
                       :object-type 'alist
                       :array-type 'list
                       :false-object nil
                       :null-object nil)))

(defun koprotk--write-json (file object)
  "Write OBJECT as JSON to FILE."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file
      (insert (json-encode object)))))

(defun koprotk--refuse-prompt (prompt &rest _)
  "Signal an error instead of asking PROMPT, which no one is there to answer."
  (error "Emacs asked a question and was not answered: %s" prompt))

(defun koprotk--agent-shell-pids ()
  "Return the pids of live ACP client processes of all agent-shell buffers."
  (let (pids)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (derived-mode-p 'agent-shell-mode)
                   (boundp 'agent-shell--state)
                   agent-shell--state)
          (let ((proc (map-nested-elt agent-shell--state '(:client :process))))
            (when (and (processp proc) (process-live-p proc))
              (push (process-id proc) pids))))))
    pids))

(defun koprotk--from-agent-shell-p (ancestor-pids)
  "Non-nil if an agent-shell client process is among ANCESTOR-PIDS.
ANCESTOR-PIDS are the ancestors of the calling hook, so this is true only
when Claude Code was launched by agent-shell in this Emacs."
  (cl-intersection (koprotk--agent-shell-pids) ancestor-pids))

(defun koprotk-run (payload-file handler &optional gate)
  "Read PAYLOAD-FILE, call HANDLER on the payload, write the outcome.
HANDLER returns an alist merged into the result.  Errors become
{ok: false, error: ...}.  The outcome goes to the payload's result_file.
GATE, when given, is called with the payload and must return non-nil to
authorize the operation.  When GATE is omitted, HANDLER only runs when the
caller descends from an agent-shell process (Claude Code via agent-shell);
otherwise the result is {ok: true, agent_shell: false}."
  (let* ((payload (koprotk--read-json payload-file))
         (result-file (alist-get 'result_file payload))
         (allowed (if gate
                      (funcall gate payload)
                    (koprotk--from-agent-shell-p (alist-get 'ancestor_pids payload))))
         (result
          (condition-case err
              (if (not allowed)
                  '((ok . t) (agent_shell . :json-false))
               (let ((large-file-warning-threshold nil)
                    (enable-local-variables :safe)
                    (use-dialog-box nil))
                ;; A prompt would block emacsclient forever; fail instead.
                (cl-letf (((symbol-function 'yes-or-no-p) #'koprotk--refuse-prompt)
                          ((symbol-function 'y-or-n-p) #'koprotk--refuse-prompt))
                  `((ok . t) (agent_shell . t) ,@(funcall handler payload)))))
            (error `((ok . :json-false)
                     (error . ,(error-message-string err)))))))
    (koprotk--write-json result-file result)
    "done"))

(defun koprotk-gate-apply (payload-file)
  "Entry point: report whether the caller descends from agent-shell."
  (koprotk-run payload-file (lambda (_payload) nil)))

(provide 'koprotk-core)

;;; koprotk-core.el ends here
