;;; koprotk-search.el --- Run agent content searches inside Emacs  -*- lexical-binding: t; -*-

;; Called through emacsclient by hooks/route-edits.py.  `koprotk-search-apply'
;; runs ripgrep from Emacs (so it uses Emacs' `exec-path' and the project's
;; default directory) and returns the hits to the agent.  Optionally the hits
;; are also shown in an xref buffer for the user.
;;
;; ripgrep is run directly, not through `xref-matches-in-directory', because
;; xref translates Emacs regexps to grep syntax and would mangle the Rust
;; regexes the agent writes.

;;; Code:

(require 'subr-x)

(defvar xref-show-xrefs-function)
(declare-function koprotk-run "koprotk-core")
(declare-function xref--show-xref-buffer "xref")
(declare-function xref-make-match "xref")
(declare-function xref-make-file-location "xref")

(defgroup koprotk nil
  "Hook-driven Emacs operations for coding agents."
  :group 'tools)

(defcustom koprotk-search-show-results nil
  "When non-nil, also show content-search hits in an xref buffer.
The buffer is displayed without selecting its window."
  :type 'boolean
  :group 'koprotk)

(defconst koprotk-search--default-limit 250
  "Number of result lines returned when the agent gives no head_limit.")

(defconst koprotk-search--max-chars 100000
  "Hard cap on the characters of search output returned to the agent.")

(defun koprotk-search--path-arg (path cwd)
  "Return PATH as an argument relative to CWD when it lies inside CWD."
  (let ((rel (file-relative-name path cwd)))
    (if (string-prefix-p ".." rel) path rel)))

(defun koprotk-search--args (payload)
  "Build the ripgrep argument list for PAYLOAD."
  (let* ((cwd (alist-get 'cwd payload))
         (mode (or (alist-get 'mode payload) "files_with_matches"))
         (path (koprotk-search--path-arg
                (expand-file-name (or (alist-get 'path payload) cwd) cwd) cwd))
         (args (list "--no-config" "--color" "never" "--sort" "path")))
    (pcase mode
      ("files_with_matches" (setq args (append args '("--files-with-matches"))))
      ("count" (setq args (append args '("--count" "--with-filename"))))
      (_ (setq args (append args '("--no-heading" "--with-filename")))
         (when (alist-get 'line_numbers payload)
           (setq args (append args '("--line-number"))))
         (dolist (opt '((after . "-A") (before . "-B") (context . "-C")))
           (when-let* ((n (alist-get (car opt) payload)))
             (setq args (append args (list (cdr opt) (format "%s" n))))))))
    (when (alist-get 'ignore_case payload)
      (setq args (append args '("--ignore-case"))))
    (when (alist-get 'multiline payload)
      (setq args (append args '("--multiline" "--multiline-dotall"))))
    (when-let* ((glob (alist-get 'glob payload)))
      (setq args (append args (list "--glob" glob))))
    (when-let* ((type (alist-get 'type payload)))
      (setq args (append args (list "--type" type))))
    (append args (list "-e" (alist-get 'pattern payload) "--" path))))

(defun koprotk-search--rg (args dir)
  "Run ripgrep with ARGS in DIR.  Return (STATUS STDOUT STDERR)."
  (let ((rg (or (executable-find "rg")
                (user-error "ripgrep (rg) not found in Emacs' exec-path")))
        (default-directory (file-name-as-directory dir))
        (errfile (make-temp-file "koprotk-rg-err"))
        (coding-system-for-read 'utf-8))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process rg nil (list t errfile) nil args)))
            (list status
                  (buffer-string)
                  (with-temp-buffer
                    (insert-file-contents errfile)
                    (string-trim (buffer-string))))))
      (delete-file errfile))))

(defun koprotk-search--limit (lines offset limit)
  "Apply OFFSET and LIMIT (0 means unlimited) to LINES.
Return (SHOWN-LINES . NOTE)."
  (let* ((total (length lines))
         (lines (nthcdr (or offset 0) lines))
         (limit (or limit koprotk-search--default-limit))
         (shown (if (and (> limit 0) (> (length lines) limit))
                    (seq-take lines limit)
                  lines)))
    (cons shown
          (when (< (+ (or offset 0) (length shown)) total)
            (format "[showing %d of %d lines from offset %d; raise head_limit or use offset for more]"
                    (length shown) total (or offset 0))))))

(defun koprotk-search--show (lines cwd)
  "Show content-mode LINES (file:line:text) in an xref buffer.  Never signals."
  (ignore-errors
    (require 'xref)
    (let (items)
      (dolist (line lines)
        (when (string-match "\\`\\(.+?\\):\\([0-9]+\\):\\(.*\\)\\'" line)
          (let ((text (match-string 3 line)))
            (push (xref-make-match
                   text
                   (xref-make-file-location
                    (expand-file-name (match-string 1 line) cwd)
                    (string-to-number (match-string 2 line))
                    0)
                   (length text))
                  items))))
      (when items
        (let ((xref-show-xrefs-function #'xref--show-xref-buffer))
          (save-selected-window
            (xref-show-xrefs (lambda () (nreverse items)) nil)))))))

(defun koprotk-search--dispatch (payload)
  "Run the search described by PAYLOAD and return a result alist."
  (let* ((cwd (file-name-as-directory (alist-get 'cwd payload)))
         (result (koprotk-search--rg (koprotk-search--args payload) cwd))
         (status (nth 0 result))
         (out (nth 1 result))
         (err (nth 2 result)))
    (when (and (> status 1) (string-empty-p out))
      (user-error "ripgrep failed: %s" (if (string-empty-p err) (format "exit %s" status) err)))
    (let* ((lines (mapcar (lambda (l) (string-remove-prefix "./" l))
                          (split-string out "\n" t)))
           (limited (koprotk-search--limit lines
                                           (alist-get 'offset payload)
                                           (alist-get 'head_limit payload)))
           (text (string-join (car limited) "\n")))
      (when (and koprotk-search-show-results
                 (equal (alist-get 'mode payload) "content"))
        (koprotk-search--show (car limited) cwd))
      (when (> (length text) koprotk-search--max-chars)
        (setq text (concat (substring text 0 koprotk-search--max-chars)
                           "\n[output truncated]")))
      `((matches . ,(length lines))
        (output . ,(if (string-empty-p text) "No matches found" text))
        (note . ,(cdr limited))))))

(defun koprotk-search-apply (payload-file)
  "Run the search described in PAYLOAD-FILE; write the outcome to its result_file."
  (koprotk-run payload-file #'koprotk-search--dispatch))

(provide 'koprotk-search)

;;; koprotk-search.el ends here
