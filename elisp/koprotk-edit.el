;;; koprotk-edit.el --- Apply agent file edits inside Emacs  -*- lexical-binding: t; -*-

;; Called through emacsclient by hooks/route-edits.py.  `koprotk-edit-apply'
;; performs the edit in the file's buffer and saves it (see koprotk-core.el
;; for the payload/result protocol).

;;; Code:

(declare-function koprotk-run "koprotk-core")

(defun koprotk-edit--buffer (file)
  "Return an up-to-date, writable buffer visiting FILE.
Signal a `user-error' if the buffer has unsaved changes or is read-only."
  (let* ((existing (find-buffer-visiting file))
         (buf (cond
               ((null existing)
                (find-file-noselect file))
               ((buffer-modified-p existing)
                (user-error "Buffer %s has unsaved changes; save or revert it first"
                            (buffer-name existing)))
               (t
                (with-current-buffer existing
                  (unless (verify-visited-file-modtime existing)
                    (revert-buffer t t t)))
                existing))))
    (when (buffer-local-value 'buffer-read-only buf)
      (user-error "Buffer %s is read-only (file not writable, or read-only-mode is on); \
make it writable and run (read-only-mode -1) in the buffer"
                  (buffer-name buf)))
    buf))

(defun koprotk-edit--diff (intended saved)
  "Return a unified diff from INTENDED to SAVED, or nil if identical."
  (unless (string= intended saved)
    (require 'diff)
    (let ((a (generate-new-buffer " *koprotk-a*" t))
          (b (generate-new-buffer " *koprotk-b*" t))
          (out (generate-new-buffer " *koprotk-diff*" t)))
      (unwind-protect
          (progn
            (with-current-buffer a (insert intended))
            (with-current-buffer b (insert saved))
            (diff-no-select a b "-u" t out)
            (with-current-buffer out
              (goto-char (point-min))
              (let ((start (if (re-search-forward "^@@" nil t)
                               (match-beginning 0)
                             (point-min)))
                    (end (if (re-search-forward "^Diff finished" nil t)
                             (match-beginning 0)
                           (point-max))))
                (truncate-string-to-width
                 (string-trim (buffer-substring-no-properties start end))
                 3000 nil nil "\n[diff truncated]"))))
        (mapc #'kill-buffer (list a b out))))))

(defun koprotk-edit--rollback (buf)
  "Discard the unsaved edit in BUF after a failed save."
  (with-current-buffer buf
    (if (and buffer-file-name (file-exists-p buffer-file-name))
        (revert-buffer t t t)
      (set-buffer-modified-p nil)
      (kill-buffer buf))))

(defun koprotk-edit--new-hook-errors (marker)
  "Return save-hook error lines logged in *Messages* after MARKER, or nil.
Emacs demotes errors from `before-save-hook' and `after-save-hook' to
messages, so a failing hook does not abort the save."
  (when-let* ((msgs (get-buffer "*Messages*")))
    (with-current-buffer msgs
      (let ((case-fold-search t) lines)
        (save-excursion
          (goto-char marker)
          (while (re-search-forward "^.*save[- ]hook error.*$" nil t)
            (push (match-string-no-properties 0) lines)))
        (when lines
          (string-join (nreverse lines) "\n"))))))

(defun koprotk-edit--save (buf)
  "Save BUF with `save-buffer' (running all save hooks).
Return an alist describing how the saved text differs from the text before
saving, and any save-hook errors.  If the save itself fails, roll the edit
back and signal an error."
  (with-current-buffer buf
    (let* ((intended (save-restriction
                       (widen)
                       (buffer-substring-no-properties (point-min) (point-max))))
           (msgs (get-buffer-create "*Messages*"))
           (mark (with-current-buffer msgs (copy-marker (point-max)))))
      (condition-case err
          (save-buffer)
        (error
         (koprotk-edit--rollback buf)
         (error "Save failed, edit rolled back: %s" (error-message-string err))))
      (let ((saved (save-restriction
                     (widen)
                     (buffer-substring-no-properties (point-min) (point-max)))))
        `((save_diff . ,(koprotk-edit--diff intended saved))
          (hook_errors . ,(koprotk-edit--new-hook-errors mark))
          (unsaved . ,(and (buffer-modified-p) t)))))))

(defun koprotk-edit--edit (file old new replace-all)
  "Replace OLD with NEW in FILE's buffer and save.  Return a result alist."
  (unless (file-exists-p file)
    (user-error "File does not exist: %s" file))
  (when (or (null old) (string-empty-p old))
    (user-error "old_string must not be empty"))
  (when (equal old new)
    (user-error "old_string and new_string are identical"))
  (let ((buf (koprotk-edit--buffer file))
        (count 0)
        save-info)
    (with-current-buffer buf
      (save-excursion
        (save-restriction
          (widen)
          (let ((case-fold-search nil))
            (goto-char (point-min))
            (while (search-forward old nil t)
              (setq count (1+ count)))
            (cond
             ((zerop count)
              (user-error "String to replace not found in %s" file))
             ((and (> count 1) (not replace-all))
              (user-error
               "Found %d matches in %s; add context to make old_string unique, or use replace_all"
               count file)))
            (undo-boundary)
            (goto-char (point-min))
            (while (search-forward old nil t)
              (replace-match new t t))
            (undo-boundary)))))
    (setq save-info (koprotk-edit--save buf))
    `((message . ,(format "%d replacement%s in %s, saved"
                          count (if (= count 1) "" "s") (buffer-name buf)))
      ,@save-info)))

(defun koprotk-edit--write (file content)
  "Make FILE's buffer contain CONTENT and save.  Return a result alist."
  (let* ((existed (file-exists-p file))
         (buf (if existed
                  (koprotk-edit--buffer file)
                (make-directory (file-name-directory file) t)
                (find-file-noselect file))))
    (with-current-buffer buf
      (save-restriction
        (widen)
        (undo-boundary)
        (let ((source (generate-new-buffer " *koprotk-source*" t)))
          (unwind-protect
              (progn
                (with-current-buffer source (insert content))
                (replace-buffer-contents source 2))
            (kill-buffer source)))
        (undo-boundary))
      (unless existed
        (set-buffer-modified-p t)))
    (let ((save-info (koprotk-edit--save buf)))
      `((message . ,(format "%s %s, saved"
                            (if existed "Updated" "Created") (buffer-name buf)))
        ,@save-info))))

(defun koprotk-edit--dispatch (payload)
  "Run the operation described by PAYLOAD and return a result alist."
  (let ((op (alist-get 'op payload))
        (file (expand-file-name (alist-get 'file payload))))
    (cond
     ((equal op "edit")
      (koprotk-edit--edit file
                          (alist-get 'old payload)
                          (alist-get 'new payload)
                          (alist-get 'replace_all payload)))
     ((equal op "write")
      (koprotk-edit--write file (or (alist-get 'content payload) "")))
     (t (user-error "Unknown op: %s" op)))))

(defun koprotk-edit-apply (payload-file)
  "Apply the edit described in PAYLOAD-FILE; write the outcome to its result_file."
  (koprotk-run payload-file #'koprotk-edit--dispatch))

(provide 'koprotk-edit)

;;; koprotk-edit.el ends here
