;;; reval.el --- Remote elisp eval. -*- lexical-binding: t -*-

;; Author: Tom Gillespie
;; Homepage: https://github.com/tgbugs/orgstrap
;; Version: 9999
;; Package-Requires: ((emacs "24.4"))
;; Is-Version-Of: https://raw.githubusercontent.com/tgbugs/orgstrap/master/reval.el
;; Reval-Get-Immutable: reval--reval-update

;;;; License and Commentary

;; License:
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; reval.el implements eval of remote elisp code. It implements
;; somewhat secure local evaluation of remote elisp by only running
;; `eval-buffer' when the checksum of the remote matches the checksum
;; embedded in the reval expression. If the checksum passes the remote
;; file is cached to avoid future calls to the network.
;;
;; To make it easier to maintain files using remote elisp code, reval
;; provides functionality to check for updates, and streamlines the
;; process for auditing new files and changes via `reval-sync'.

;;; Code:

(require 'cl-lib)

(defgroup reval nil
  "Minimal remote evaluation of elisp code."
  :tag "reval"
  :group 'applications)

(defcustom reval-default-cypher 'sha256
  "Default cypher to use to fill in a hole in `reval'."
  :type 'symbol
  :options (if (fboundp #'secure-hash-algorithms) (secure-hash-algorithms) '(sha256))
  :group 'reval)

(defvar reval-cache-directory (concat user-emacs-directory "reval/cache/")
  "The directory where retrieved .el files are saved.")

(defvar reval-failed-buffer-list nil "List of failed reval buffers.") ; XXX FIXME this is dumb
;; use the buffer to track the state using `reval-fail' because then
;; the process composes with the other tools we have for interacting
;; with revaled files and caches etc.

(defvar reval-evaled-buffer-list nil "List of evaled reval buffers.")

(defvar-local reval--pending-updates nil
  "Internal variable use to coordinate updates for a single buffer.")

(defmacro with-url-handler-mode (&rest body)
  "Run BODY with `url-handler-mode' enabled."
  (declare (indent defun))
  `(let ((uhm url-handler-mode))
     (unwind-protect
         (progn
           (url-handler-mode)
           ,@body)
       (unless uhm
         (url-handler-mode 0)))))

(defun reval-id->buffer (path-or-url)
  "Given a PATH-OR-URL return a buffer of its contents."
  ;; We explicitly do not catch errors here since they need to
  ;; be caught by the human in the loop later.
  (with-url-handler-mode
    (find-file-noselect path-or-url)))

(defun reval-resum-review (cypher buffer &optional review)
  "Return checksum under CYPHER for BUFFER.
If REVIEW is non-nil then switch to BUFFER and prompt asking if audit
is ok before continuing."
  ;; we don't need to check or review alternates here because they
  ;; must all be identical
  (let (enable-local-eval)
    (save-excursion
      (save-window-excursion
        (with-current-buffer buffer
          (unless (file-exists-p (buffer-file-name))
            ;; NOTE url-handler-mode must be set in the calling context
            ;; this case should not happen, only extant files should make it here
            (error "reval-resum: file does not exist! %s" (buffer-file-name)))
          (when review
            (switch-to-buffer (current-buffer))
            ;; FIXME `yes-or-no-p' still blocks the command loop in >= 27 emacsclient
            (unless (yes-or-no-p "Audit of file ok? ") ; not using `y-or-n-p' since it is too easy
              (error "Audit failed.  Checksum will not be calculated for %s"
                     (buffer-file-name (current-buffer)))))

          ;; need to ensure that file is actually elisp
          ;; note that in some cases read can succeed
          ;; even when a file is not elisp e.g. an html
          ;; file can sometimes read without error but
          ;; will fail on eval

          ;; elisp check by major mode
          (unless (eq major-mode 'emacs-lisp-mode)
            (error "Not an Emacs Lisp file!"))

          ;; elisp check by read
          (condition-case nil
              (read (concat "(progn\n"
                            (buffer-substring-no-properties (point-min) (point-max))
                            "\n)"))
            (error (error "Not an Emacs Lisp file!")))

          ;; return the checksum
          (intern (secure-hash cypher (current-buffer))))))))

(defun reval-resum-minimal (cypher buffer)
  "Checksum of BUFFER under CYPHER." ; minimal for maximal porability
  ;; not used since the expression takes up less space
  (intern (secure-hash cypher buffer)))

(defalias 'reval-resum #'reval-resum-review)

(defvar reval--make-audit t "Dynamic variable to control audit during `reval--make'.")
;; the control of audit behavior is intentionally excluded from the
;; arguments of `reval--make' so that top level calls must audit
(defun reval--make (cypher path-or-url)
  "Make a `reval' expression from CYPHER and PATH-OR-URL.
This should not be used directly at the top level see docs for `reval'
for a better workflow."
  (unless reval--make-audit
    (warn "`reval--make' not auditing %S" path-or-url))
  (let ((checksum (reval-resum-review cypher (reval-id->buffer path-or-url) reval--make-audit)))
    `(reval ',cypher ',checksum ,path-or-url)))

(defun reval-audit (&optional universal-argument)
  "Audit the reval under the cursor." ; FIXME this needs a LOT of work
  (interactive)
  (cl-multiple-value-bind (cypher checksum path-or-url _alternates _b _e) ; FIXME probably loop here
      (reval--form-at-point)
    (let* ((buffer (with-url-handler-mode
                     (find-file-noselect path-or-url)))
           (buffer-checksum (reval-resum cypher buffer t)))
      (eq buffer-checksum checksum))))

(defun reval--add-buffer-to-list (buffer buffer-list-name)
  "Add BUFFER to list at BUFFER-LIST-NAME."
  (with-current-buffer buffer ; FIXME do this in both cases but change which list
    (push buffer (symbol-value buffer-list-name))
    ;; push first since it is better to have a dead buffer linger in a list
    ;; than it is to have an error happen during execution of `kill-buffer-hook'
    (let ((buffer-list-name buffer-list-name))
      (add-hook 'kill-buffer-hook
                (lambda ()
                  ;; read the manual for sets and lists to see why we have to
                  ;; setq here ... essentially if our element is found in the
                  ;; car of the list then the underlying list is not modified
                  ;; and the cdr of the list is returned, therefore if you have
                  ;; a list of all zeros and try to delete zero from it the list
                  ;; will remain unchanged unless you also setq the name to the
                  ;; (now) cdr value
                  (set buffer-list-name
                       (delete (current-buffer) (symbol-value buffer-list-name))))
                nil t))))

(defun reval-cache-path (checksum &optional basename)
  "Return the path to the local cache for a given CHECKSUM.
If BASENAME is provided a wildcard is not used.  This is mostly
to make the calls more human readable for debugging but also
makes it easier to catch cases where the wrong checksum was passed."
  (let* ((name (symbol-name checksum))
         (subdir (substring name 0 2))
         (cache-path (concat reval-cache-directory subdir "/" name "-" (or basename "*"))))
    (if basename
        cache-path
      (let ((expanded (file-expand-wildcards cache-path)))
        (if expanded
            ;; I guess a strict rename could hit a dupe but hitting a
            ;; hash collision here would be ... astronimical odds
            (car expanded)
          nil)))))

(defun reval--write-cache (buffer cache-path)
  "Write BUFFER to CACHE-PATH.  Create the parent if it doesn not exist."
  (let ((parent-path (file-name-directory cache-path))
        make-backup-files)
    (unless (file-directory-p parent-path)
      (make-directory parent-path t))
    (with-current-buffer buffer
      (write-file cache-path))))

(defun reval-find-cache (&optional universal-argument)
  "Jump to the cache for a given reval call.
At the moment UNIVERSAL-ARGUMENT is a placeholder."
  (interactive)
  (cl-multiple-value-bind (_cypher checksum path-or-url _alternates _b _e)
      (reval--form-at-point)
    (let ((cache-path (reval-cache-path checksum)))
      (if (file-exists-p cache-path)
          (let ((buffer (find-file-noselect cache-path)))
            (with-current-buffer buffer (emacs-lisp-mode))
            (pop-to-buffer-same-window buffer))
        (error "No cache for %s" path-or-url)))))

(defun reval-fail (&rest args)
  "Embed in buffer if audit fails on ARGS so that there is a record."
  (error "reval audit failed for: %S" args))

(defun reval (cypher checksum path-or-url &rest alternates)
  "Open PATH-OR-URL, match CHECKSUM under CYPHER, then eval.
If an error is encountered try ALTERNATES in order.

The simplest way to populate a `reval' expression starting from just
PATH-OR-URL is to write out expression with CYPHER and CHECKSUM as a
nonsense values.  For example (reval ? ? \"path/to/file.el\").  Then
run \\[reval-update-simple] (M-x `reval-update-simple') to populate
CYPHER and CHECKSUM."
  (reval--get-buffer cypher checksum path-or-url alternates #'eval-buffer))

(defun reval--get-buffer (cypher checksum path-or-url &optional alternates do-with-buffer)
  "generic implementation that gets a buffer and can run a function
DO-WITH-BUFFER in that buffer to enforce invariants, eval the buffer, etc.
Note that this function ALWAYS returns the buffer, so DO-WITH-BUFFER should only
be used to trigger a failure mode before the buffer is retruned, not used to get
a return value from the buffer."
  (let (found-buffer (cache-path (reval-cache-path checksum (file-name-nondirectory path-or-url))))
    (with-url-handler-mode
      (cl-loop for path-or-url in (cons cache-path (cons path-or-url alternates))
               do (if (file-exists-p path-or-url)
                      (let* ((buffer (reval-id->buffer path-or-url))
                             (_ (when (string= path-or-url cache-path)
                                  (with-current-buffer buffer (emacs-lisp-mode))))
                             ;; FIXME this is still not right ... can error due to not elisp
                             (buffer-checksum (reval-resum cypher buffer)))
                        (if (eq buffer-checksum checksum)
                            (let ((buffer
                                   (if (string= path-or-url cache-path)
                                       buffer
                                     ;; save to cache and switch buffer before eval for xrefs
                                     (reval--write-cache buffer cache-path)
                                     (find-file-noselect cache-path))))
                              (when do-with-buffer
                                (with-current-buffer buffer
                                  (funcall do-with-buffer)))
                              (setq found-buffer buffer))
                          (reval--add-buffer-to-list buffer 'reval-failed-buffer-list)
                          (funcall (if alternates #'warn #'error)
                                   ;; if alternates warn to prevent an early failure
                                   ;; from blocking later potential successes otherwise
                                   ;; signal an error
                                   "reval: checksum mismatch! %s" path-or-url)))
                    (warn "reval: file does not exist! %s" path-or-url))
               until found-buffer))
    (unless found-buffer
      (error "reval: all paths failed!"))
    found-buffer))

(defun reval-view-failed ()
  "View top of failed reval buffer stack and kill or keep."
  (interactive)
  (when reval-failed-buffer-list
    (save-window-excursion
      (with-current-buffer (car reval-failed-buffer-list)
        (switch-to-buffer (current-buffer))
        (when (y-or-n-p "Kill buffer? ")
          (kill-buffer))))))

;;; machinery to get the latest immutable url for a revaled file

(require 'lisp-mnt)

(defvar url-http-end-of-headers)
(defun reval-url->json (url)  ; see utils.el
  "Given a URL string return json as a hash table."
  (json-parse-string
   (with-current-buffer (url-retrieve-synchronously url)
     (buffer-substring url-http-end-of-headers (point-max)))))

(defun reval--get-new-immutable-url ()
  "Get the immutable url for the current buffer."
  (let ((get-imm-name (reval-header-get-immutable)))
    (if get-imm-name
        (let ((get-imm (intern get-imm-name)))
          (if (fboundp get-imm)
              (funcall get-imm)
            (warn "Function %s from Reval-Get-Immutable not found in %s" get-imm-name (buffer-file-name))
            nil))
      (warn "Reval-Get-Immutable: header not found in %s" (buffer-file-name))
      nil)))

(defun reval-get-imm-github (group repo path &optional branch)
  "Get the immutable url for PATH on BRANCH in a github remote for REPO at GROUP."
  (let* ((branch (or branch "master"))
         (branch-url
          (format "https://api.github.com/repos/%s/%s/git/refs/heads/%s"
                  group repo branch))
         (branch-sha (gethash "sha" (gethash "object" (reval-url->json branch-url))))
         (url
          (format "https://api.github.com/repos/%s/%s/commits?path=%s&page=1&per_page=1&sha=%s"
                  group repo path branch-sha))
         (result (reval-url->json url))
         (sha (gethash "sha" (elt (reval-url->json url) 0))))
    (format "https://raw.githubusercontent.com/%s/%s/%s/%s" group repo sha path)))

(defun reval-header-is-version-of (&optional file)
  "Return the Is-Version-Of: header for FILE or current buffer."
  ;; this was originally called Latest-Version but matching the
  ;; datacite relationships seems to make more sense here esp.
  ;; since this is literally the example from the documentation
  (lm-with-file file
    (lm-header "is-version-of")))

(defun reval-header-get-immutable (&optional file)
  "Return the Reval-Get-Immutable: header for FILE or current buffer.

The value of this header should name a function in the current
file that returns an immutable name that points to the current
remote version of the the current file.

The implementation of the function may assume that the reval
package is present on the system."
  ;; there will always have to be a function because even if the
  ;; remote does all the work for us we will still have to ask the
  ;; remote to actually do the dereference operation, since we can't
  ;; gurantee that all remotes even have endpoints that behave this
  ;; functionality we can't implement this once in reval, so each
  ;; file implements this pattern itself, or worst case, the
  ;; update function can be supplied at update time if there is a
  ;; useful remote file that doesn't know that it is being revaled
  (lm-with-file file
    (lm-header "reval-get-immutable")))

;;; internals for `reval-sync' workflow

(defun reval--audit-change (buffer-old url-new buffer-source cypher begin)
  "Audit the changes made in URL-NEW relative to BUFFER-OLD.
If the audit passes, a checksum is calculated under CYPHER for
the new buffer, and a new reval form is inserted into BUFFER-SOURCE
starting at position BEGIN which corresponds to the beginning of the
reval form that was the source for BUFFER-OLD."
  (let* ((buffer-new (with-url-handler-mode (find-file-noselect url-new)))
         (buffer-review (reval--diff buffer-old buffer-new)))
    ;; audit
    ;; TODO see if we need something more than this, for small diffs it seems
    ;; to work fairly well, it captures the core functionality needed, and
    ;; if users are curious about the changes, they can accept or reject,
    ;;; and then look up the changes in git without complicating this workflow
    (let*
        ((ok
          (save-excursion
            (save-window-excursion
              (with-current-buffer buffer-review
                (display-buffer buffer-review)
                ;; not using `y-or-n-p' since it is too easy
                (let ((yes (yes-or-no-p "Audit of changes ok? ")))
                  (unless yes
                    (warn "Audit failed.  Checksum will not be calculated for %s"
                          (buffer-file-name buffer-new)))
                  yes)))))
         (checksum-new (if (not ok) 'audit-failed (intern (secure-hash cypher buffer-new))))
         (to-insert
          (prin1-to-string
           `(,(if (not ok) 'reval-fail 'reval) ',cypher ',checksum-new ,url-new 'NEW))))
      (with-current-buffer buffer-source
        (save-excursion
          (goto-char begin)
          (insert to-insert "\n")))
      ok)))

(defun reval--diff (buffer-old buffer-new)
  "Construct a buffer that is the diff between BUFFER-OLD and BUFFER-NEW."
  ;;(ediff-buffers buffer-old buffer-new)
  ;; lol no-select noselect inconsistency
  (diff-no-select buffer-old buffer-new nil nil))

(defun reval--get-changed ()
  "Collect thunks to update the reval expressions in the current buffer that have new versions."
  (save-excursion
    (goto-char (point-min))
    (let (out (buffer-source (current-buffer)))
      (while (re-search-forward "(reval[[:space:]]" nil t)
        (cl-multiple-value-bind (cypher checksum path-or-url-raw alternates begin)
            (reval--form-at-point)
          (let* ((path-or-url
                  (or (and (stringp path-or-url-raw) path-or-url-raw) ; XXX why does stringp return t !??!?
                      ;; FIXME DANGERZONE !? (yes very)
                      (eval path-or-url-raw)))
                 (buffer
                  (reval--get-buffer
                   cypher checksum path-or-url alternates
                   #'reval--eval-buffer-when-not-fboundp))
                 (url-new (with-current-buffer buffer (reval--get-new-immutable-url))))
            (unless (string= url-new path-or-url)
              ;; FIXME TODO local urls should check for version control so that
              ;; checksums can be updated before pushing, but that is more involved
              (setq
               out
               (cons
                (list
                 (reval--make-diff-thunk buffer url-new buffer-source cypher begin)
                 alternates)
                out)))))
        (forward-sexp))
      out)))

(defun reval--eval-buffer-when-not-fboundp ()
  "Run inside `reval--get-buffer' to avoid revaling the buffer if
the imm url function if it is already fboundp"
  (let ((get-imm-name (reval-header-get-immutable)))
    (if get-imm-name
        (let ((get-imm (intern get-imm-name)))
          (unless (fboundp get-imm)
            (eval-buffer))))))

(defun reval--make-diff-thunk (buffer-old url-new buffer-source cypher begin)
  "Create the thunk that kicks off the update workflow."
  (lambda () (reval--audit-change buffer-old url-new buffer-source cypher begin)))

(defun reval--dquote-symbolp (thing)
  "Match pattern ''THING.
Useful when dealing with quoted symbols in the outpub or a `read'.
For example elt 2 of '(reval 'sha256 ? \"file.el\")."
  (and (consp thing)
       (eq (car thing) 'quote)
       (consp (cdr thing))
       (symbolp (cadr thing))))

(defun reval--form-at-point ()
  "Extract the components of the reval expression at the current point."
  (save-excursion
    (re-search-forward " ")
    (re-search-backward "(reval[[:space:]]")
    (let ((begin (point)))
      (forward-sexp)
      (let ((raw (read (buffer-substring-no-properties begin (point))))
            (end (point)))
        ;;(message "aaaaa: %S %S %S" raw (symbolp (elt raw 1)) (type-of (elt raw 1)))
        (let ((cypher (let ((cy (elt raw 1)))
                        ;; '(sigh 'sigh) XXX the usual eval dangerzone >_<
                        (if (reval--dquote-symbolp cy) (eval cy) reval-default-cypher)))
              (checksum (let ((cs (elt raw 2)))
                          (if (reval--dquote-symbolp cs) (eval cs) nil)))
              (path-or-url (elt raw 3))
              (alternates (cddddr raw)))
          (cl-values cypher checksum path-or-url alternates begin end))))))

(defun reval-check-for-updates (&optional universal-argument) ; TODO reval-sync ?
  "Check current buffer revals for updates.
UNIVERSAL-ARGUMENT is a placeholder."
  (interactive)
  ;; search and collect all calls to reval in the current buffer? all org files? ???
  ;; open the current reval in a buffer
  ;; get the package info if avaiable
  ;; warn about all revals that cannot be updated due to missing metadata?
  (let* ((pending-updates (reval--get-changed))
         (count (length pending-updates))
         (updates? (if (> count 1) "updates" "update")))
    (setq-local reval--pending-updates pending-updates)
    ;; TODO display a message about pending updates or a buffer
    ;; with the pending updates? probably easier to do the latter
    ;; and have approve/deny buttons or something
    (if (> count 0)
        (message "%s %s found for %s run `reval-do-updates' to audit changes."
                 count updates? (buffer-file-name))
      (message "No reval updates found for %s" (buffer-file-name)))))

(defun reval-do-updates (&optional universal-argument)
  "Audit and insert pending updates.
UNIVERSAL-ARGUMENT is a placeholder."
  ;; XXX `reval-update' isn't here because it would be for a single
  ;; form, but our workflow doesn't do that right now
  (interactive)
  (while reval--pending-updates
    (let* ((update (pop reval--pending-updates))
           (do-update (car update))
           (success (funcall do-update))))))

(defun reval-form-checksum-at-point (&optional universal-argument)
  "Get the checksum in the reval form at point.  UNIVERSAL-ARGUMENT is a placeholder."
  (interactive)
  (cl-multiple-value-bind (_cypher checksum _path-or-url _alternates _b _e)
      (reval--form-at-point)
    checksum))

;; user facing functionality

(defun reval-update-simple (&optional universal-argument)
  "Update the checksum for the reval sexp under the cursor or up the page.
Useful when developing against a local path or a mutable remote id.
If UNIVERSAL-ARGUMENT is non-nil then `reval-audit' is skipped, please use
this functionality responsibly."
  (interactive "P")
  (with-url-handler-mode
    (let ((reval--make-audit (not universal-argument))
          (sigh (point)))
      (cl-multiple-value-bind (cypher checksum path-or-url alternates begin end)
          (reval--form-at-point)
        (unless (memq cypher (secure-hash-algorithms))
          (error "%S is not a known member of `secure-hash-algorithms'" cypher))
        (let ((new (reval--make cypher path-or-url))
              (print-quoted t)
              print-length
              print-level)
          (delete-region begin end)
          (insert (prin1-to-string
                   (if alternates ; don't cons the old checksum, repeated invocations grow
                       (append new (cons ''OLD> alternates))
                     new))))
        (goto-char sigh)))))

(defun reval-sync (&optional universal-argument)
  "Check for, audit, and insert updates for the current buffer.
UNIVERSAL-ARGUMENT is a placeholder."
  (interactive)
  (reval-check-for-updates)
  (when reval--pending-updates
    (reval-do-updates)))


(defun reval--reval-update ()
  "Get the immutable url for the current remote version of this file."
  (reval-get-imm-github "tgbugs" "orgstrap" "reval.el"))

(provide 'reval)

;;; reval.el ends here
