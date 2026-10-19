;;; koprotk-core.el --- Shared plumbing for hook-driven Emacs operations  -*- lexical-binding: t; -*-

;; The hooks (hooks/route-edits.py) call Emacs through emacsclient.  Each call
;; passes a JSON payload file; the operation's result is written as JSON to
;; the payload's result_file so no output parsing is needed.

;;; Code:

(require 'cl-lib)
(require 'json)

(defun koprotk--read-json (file)
  "Parse FILE as JSON into an alist (false and null become nil)."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (goto-char (point-min))
    (json-parse-string (buffer-string)
                       :object-type 'alist
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

(defun koprotk-run (payload-file handler)
  "Read PAYLOAD-FILE, call HANDLER on the payload, write the outcome.
HANDLER returns an alist merged into the result.  Errors become
{ok: false, error: ...}.  The outcome goes to the payload's result_file."
  (let* ((payload (koprotk--read-json payload-file))
         (result-file (alist-get 'result_file payload))
         (result
          (condition-case err
              (let ((large-file-warning-threshold nil)
                    (enable-local-variables :safe)
                    (use-dialog-box nil))
                ;; A prompt would block emacsclient forever; fail instead.
                (cl-letf (((symbol-function 'yes-or-no-p) #'koprotk--refuse-prompt)
                          ((symbol-function 'y-or-n-p) #'koprotk--refuse-prompt))
                  `((ok . t) ,@(funcall handler payload))))
            (error `((ok . :json-false)
                     (error . ,(error-message-string err)))))))
    (koprotk--write-json result-file result)
    "done"))

(provide 'koprotk-core)

;;; koprotk-core.el ends here
