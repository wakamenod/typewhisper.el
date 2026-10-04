;;; typewhisper-dictionary.el --- Manage the TypeWhisper dictionary  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 wakamenod

;; This file is not part of GNU Emacs.

;;; Commentary:

;; List and edit TypeWhisper corrections and terms, and confirm which
;; fixes made by `typewhisper-fix' should be registered.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'typewhisper-api)

(defcustom typewhisper-register-min-length 2
  "Minimum length of an original string to register as a correction.
Shorter strings match too often and are not selected by default."
  :group 'typewhisper
  :type 'integer)

(defcustom typewhisper-register-min-hiragana-length 3
  "Minimum length of a hiragana-only original string to register.
Short hiragana words match too often and are not selected by default."
  :group 'typewhisper
  :type 'integer)

;;;; Shared helpers

(defun typewhisper-dictionary--filter-match-p (filter &rest strings)
  "Return non-nil if FILTER is empty or a substring of any of STRINGS."
  (or (null filter) (string-empty-p filter)
      (cl-some (lambda (s) (string-search (downcase filter) (downcase s)))
               strings)))

(defvar-local typewhisper-dictionary--filter nil
  "Substring used to filter the list in the current buffer.")

(defun typewhisper-dictionary-filter (filter)
  "Show only entries containing FILTER.  An empty FILTER shows all."
  (interactive (list (read-string "Filter (empty for all): "
                                  typewhisper-dictionary--filter)))
  (setq typewhisper-dictionary--filter
        (if (string-empty-p filter) nil filter))
  (revert-buffer))

(defun typewhisper-dictionary--mode-line-filter ()
  "Show the filter in the mode line."
  (setq mode-line-process
        '(typewhisper-dictionary--filter
          (" [" typewhisper-dictionary--filter "]"))))

;;;; Corrections

(defvar typewhisper-corrections--cache nil
  "Corrections shown in the corrections buffer.")

(defvar-keymap typewhisper-corrections-mode-map
  :parent tabulated-list-mode-map
  "a" #'typewhisper-corrections-add
  "e" #'typewhisper-corrections-edit
  "d" #'typewhisper-corrections-delete
  "s" #'typewhisper-dictionary-filter)

(define-derived-mode typewhisper-corrections-mode tabulated-list-mode
  "TW Corrections"
  "Major mode for TypeWhisper corrections.

\\{typewhisper-corrections-mode-map}"
  (setq tabulated-list-format [("Original" 30 t)
                               ("Replacement" 30 t)
                               ("Case" 4 t)])
  (setq tabulated-list-sort-key '("Original" . nil))
  (add-hook 'tabulated-list-revert-hook #'typewhisper-corrections--refresh nil t)
  (typewhisper-dictionary--mode-line-filter)
  (tabulated-list-init-header))

(defun typewhisper-corrections--refresh ()
  "Fetch corrections and fill `tabulated-list-entries'."
  (setq typewhisper-corrections--cache (typewhisper-api-corrections))
  (setq tabulated-list-entries
        (cl-loop for c in typewhisper-corrections--cache
                 for original = (alist-get 'original c)
                 for replacement = (or (alist-get 'replacement c) "")
                 when (typewhisper-dictionary--filter-match-p
                       typewhisper-dictionary--filter original replacement)
                 collect (list original
                               (vector original replacement
                                       (if (alist-get 'caseSensitive c) "yes" "")))))
  (tabulated-list-init-header))

;;;###autoload
(defun typewhisper-corrections ()
  "List TypeWhisper corrections."
  (interactive)
  (let ((buffer (get-buffer-create "*TypeWhisper Corrections*")))
    (with-current-buffer buffer
      (typewhisper-corrections-mode)
      (typewhisper-corrections--refresh)
      (tabulated-list-print))
    (pop-to-buffer buffer)))

(defun typewhisper-corrections--entry (original)
  "Return the cached correction for ORIGINAL."
  (cl-find original typewhisper-corrections--cache
           :key (lambda (c) (alist-get 'original c)) :test #'equal))

(defun typewhisper-corrections--read (&optional original replacement case-sensitive)
  "Read a correction, using ORIGINAL, REPLACEMENT and CASE-SENSITIVE as defaults.
Return (ORIGINAL REPLACEMENT CASE-SENSITIVE)."
  (let* ((new-original (string-trim (read-string "Original: " original)))
         (new-replacement (read-string (format "Replace %s with: " new-original)
                                       replacement))
         (new-case (if (string-match-p "[[:alpha:]]" new-original)
                       (y-or-n-p (format "Case sensitive%s? "
                                         (if case-sensitive " (currently yes)" "")))
                     case-sensitive)))
    (when (string-empty-p new-original)
      (user-error "Original must not be empty"))
    (list new-original new-replacement new-case)))

(defun typewhisper-corrections-add (original replacement case-sensitive)
  "Add a correction from ORIGINAL to REPLACEMENT.
CASE-SENSITIVE non-nil makes it case sensitive."
  (interactive (typewhisper-corrections--read))
  (when (and (typewhisper-corrections--entry original)
             (not (yes-or-no-p (format "%s is already registered; overwrite? " original))))
    (user-error "Cancelled"))
  (typewhisper-api-put-correction original replacement case-sensitive)
  (revert-buffer)
  (message "Added %s → %s" original replacement))

(defun typewhisper-corrections-edit ()
  "Edit the correction at point."
  (interactive)
  (let* ((old (or (tabulated-list-get-id) (user-error "No correction at point")))
         (entry (typewhisper-corrections--entry old))
         (new (typewhisper-corrections--read
               old (alist-get 'replacement entry) (alist-get 'caseSensitive entry))))
    (pcase-let ((`(,original ,replacement ,case-sensitive) new))
      (when (and (not (equal original old))
                 (typewhisper-corrections--entry original)
                 (not (yes-or-no-p (format "%s is already registered; overwrite? " original))))
        (user-error "Cancelled"))
      (typewhisper-api-put-correction original replacement case-sensitive)
      (unless (equal original old)
        (typewhisper-api-delete-correction old))
      (revert-buffer)
      (message "Saved %s → %s" original replacement))))

(defun typewhisper-corrections-delete ()
  "Delete the correction at point."
  (interactive)
  (let ((original (or (tabulated-list-get-id) (user-error "No correction at point"))))
    (when (yes-or-no-p (format "Delete correction for %s? " original))
      (typewhisper-api-delete-correction original)
      (revert-buffer)
      (message "Deleted %s" original))))

;;;; Terms

(defvar-keymap typewhisper-terms-mode-map
  :parent tabulated-list-mode-map
  "a" #'typewhisper-terms-add
  "e" #'typewhisper-terms-edit
  "d" #'typewhisper-terms-delete
  "s" #'typewhisper-dictionary-filter)

(define-derived-mode typewhisper-terms-mode tabulated-list-mode
  "TW Terms"
  "Major mode for TypeWhisper terms.

\\{typewhisper-terms-mode-map}"
  (setq tabulated-list-format [("Term" 40 t)])
  (setq tabulated-list-sort-key '("Term" . nil))
  (add-hook 'tabulated-list-revert-hook #'typewhisper-terms--refresh nil t)
  (typewhisper-dictionary--mode-line-filter)
  (tabulated-list-init-header))

(defun typewhisper-terms--refresh ()
  "Fetch terms and fill `tabulated-list-entries'."
  (setq tabulated-list-entries
        (cl-loop for term in (typewhisper-api-terms)
                 when (typewhisper-dictionary--filter-match-p
                       typewhisper-dictionary--filter term)
                 collect (list term (vector term))))
  (tabulated-list-init-header))

;;;###autoload
(defun typewhisper-terms ()
  "List TypeWhisper terms."
  (interactive)
  (let ((buffer (get-buffer-create "*TypeWhisper Terms*")))
    (with-current-buffer buffer
      (typewhisper-terms-mode)
      (typewhisper-terms--refresh)
      (tabulated-list-print))
    (pop-to-buffer buffer)))

(defun typewhisper-terms-add (term)
  "Add TERM to the dictionary."
  (interactive (list (string-trim (read-string "Term: "))))
  (when (string-empty-p term)
    (user-error "Term must not be empty"))
  (typewhisper-api-add-terms (list term))
  (when (derived-mode-p 'typewhisper-terms-mode)
    (revert-buffer))
  (message "Added term %s" term))

(defun typewhisper-terms-edit ()
  "Rename the term at point."
  (interactive)
  (let* ((old (or (tabulated-list-get-id) (user-error "No term at point")))
         (new (string-trim (read-string "Term: " old))))
    (when (string-empty-p new)
      (user-error "Term must not be empty"))
    (unless (equal new old)
      (typewhisper-api-add-terms (list new))
      (typewhisper-api-delete-term old)
      (revert-buffer)
      (message "Renamed %s to %s" old new))))

(defun typewhisper-terms-delete ()
  "Delete the term at point."
  (interactive)
  (let ((term (or (tabulated-list-get-id) (user-error "No term at point"))))
    (when (yes-or-no-p (format "Delete term %s? " term))
      (typewhisper-api-delete-term term)
      (revert-buffer)
      (message "Deleted term %s" term))))

;;;; Guards

(defun typewhisper-dictionary--hiragana-only-p (string)
  "Return non-nil if STRING contains only hiragana."
  (string-match-p "\\`[ぁ-ゖー]+\\'" string))

(defun typewhisper-dictionary--latin-only-p (string)
  "Return non-nil if STRING contains only ASCII letters, digits and symbols."
  (string-match-p "\\`[[:ascii:]]+\\'" string))

(defun typewhisper-dictionary-check (wrong right corrections &optional raw-text)
  "Check whether WRONG → RIGHT is safe to register as a correction.
CORRECTIONS is the current list from TypeWhisper.  RAW-TEXT is the
transcription before corrections, if known.  Return a list of
\(LEVEL . MESSAGE) where LEVEL is `block' (not selected by default)
or `warn'."
  (let ((issues nil)
        (existing (cl-find wrong corrections
                           :key (lambda (c) (alist-get 'original c))
                           :test #'equal)))
    (cond
     ((< (length wrong) typewhisper-register-min-length)
      (push '(block . "too short") issues))
     ((and (typewhisper-dictionary--hiragana-only-p wrong)
           (< (length wrong) typewhisper-register-min-hiragana-length))
      (push '(block . "short hiragana word; may match too often") issues)))
    (when (and (not (equal wrong right))
               (equal (downcase wrong) (downcase right)))
      (push '(warn . "differs only in case; check case sensitivity") issues))
    (when existing
      (let ((old (alist-get 'replacement existing)))
        (push (if (equal old right)
                  '(block . "already registered")
                (cons 'warn (format "overwrites %s → %s" wrong old)))
              issues)))
    (when (and raw-text (not (string-search wrong raw-text)))
      (let ((culprits (cl-remove-if-not
                       (lambda (c)
                         (string-search wrong (or (alist-get 'replacement c) "")))
                       corrections)))
        (push (cons 'block
                    (if culprits
                        (format "not in raw text; review existing correction %s"
                                (mapconcat (lambda (c)
                                             (format "%s → %s"
                                                     (alist-get 'original c)
                                                     (alist-get 'replacement c)))
                                           culprits ", "))
                      "not in raw text; an existing correction may have produced it"))
              issues)))
    (nreverse issues)))

(defun typewhisper-dictionary--make-candidates (fixes corrections raw-text)
  "Turn FIXES into registration candidates.
CORRECTIONS and RAW-TEXT are passed to `typewhisper-dictionary-check'."
  (mapcar (lambda (fix)
            (let* ((wrong (plist-get fix :wrong))
                   (right (plist-get fix :right))
                   (issues (typewhisper-dictionary-check wrong right corrections raw-text)))
              (list :wrong wrong :right right
                    :type 'correction
                    :case-sensitive nil
                    :marked (not (assq 'block issues))
                    :issues issues)))
          fixes))

;;;; Registration

(defvar-local typewhisper-register--candidates nil
  "Candidates shown in the registration buffer.")

(defvar-keymap typewhisper-register-mode-map
  :parent tabulated-list-mode-map
  "m" #'typewhisper-register-mark
  "u" #'typewhisper-register-unmark
  "t" #'typewhisper-register-toggle-type
  "c" #'typewhisper-register-toggle-case
  "C-c C-c" #'typewhisper-register-commit
  "C-c C-k" #'typewhisper-register-discard)

(define-derived-mode typewhisper-register-mode tabulated-list-mode
  "TW Register"
  "Major mode to choose fixes to register in TypeWhisper.
Marked rows are registered with \\[typewhisper-register-commit].
\\[typewhisper-register-toggle-type] switches between a correction and
a term (the right-hand side is added as a recognition hint).

\\{typewhisper-register-mode-map}"
  (setq tabulated-list-format [("M" 1 nil)
                               ("Type" 10 nil)
                               ("Wrong" 20 nil)
                               ("Right" 20 nil)
                               ("Case" 4 nil)
                               ("Notes" 0 nil)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun typewhisper-register--print ()
  "Redisplay the candidates."
  (setq tabulated-list-entries
        (cl-loop for c in typewhisper-register--candidates
                 for i from 0
                 collect
                 (list i
                       (vector (if (plist-get c :marked) "*" " ")
                               (symbol-name (plist-get c :type))
                               (plist-get c :wrong)
                               (plist-get c :right)
                               (if (and (eq (plist-get c :type) 'correction)
                                        (plist-get c :case-sensitive))
                                   "yes" "")
                               (propertize
                                (mapconcat #'cdr (plist-get c :issues) "; ")
                                'face 'warning)))))
  (tabulated-list-print t))

(defun typewhisper-register--update (prop fn)
  "Set PROP of the candidate at point to the result of FN on its value."
  (let ((i (or (tabulated-list-get-id) (user-error "No candidate at point"))))
    (setf (nth i typewhisper-register--candidates)
          (plist-put (nth i typewhisper-register--candidates) prop
                     (funcall fn (plist-get (nth i typewhisper-register--candidates)
                                            prop))))
    (typewhisper-register--print)))

(defun typewhisper-register-mark ()
  "Mark the candidate at point and move to the next line."
  (interactive)
  (typewhisper-register--update :marked (lambda (_) t))
  (forward-line 1))

(defun typewhisper-register-unmark ()
  "Unmark the candidate at point and move to the next line."
  (interactive)
  (typewhisper-register--update :marked #'ignore)
  (forward-line 1))

(defun typewhisper-register-toggle-type ()
  "Switch the candidate at point between a correction and a term."
  (interactive)
  (typewhisper-register--update
   :type (lambda (type) (if (eq type 'correction) 'term 'correction))))

(defun typewhisper-register-toggle-case ()
  "Toggle case sensitivity of the candidate at point."
  (interactive)
  (typewhisper-register--update :case-sensitive #'not))

(defun typewhisper-register-commit ()
  "Register the marked candidates and close the buffer."
  (interactive)
  (let* ((marked (cl-remove-if-not (lambda (c) (plist-get c :marked))
                                   typewhisper-register--candidates))
         (corrections (cl-remove-if-not (lambda (c) (eq (plist-get c :type) 'correction))
                                        marked))
         (terms (delete-dups
                 (mapcar (lambda (c) (plist-get c :right))
                         (cl-remove-if-not (lambda (c) (eq (plist-get c :type) 'term))
                                           marked)))))
    (dolist (c corrections)
      (typewhisper-api-put-correction (plist-get c :wrong) (plist-get c :right)
                                      (plist-get c :case-sensitive)))
    (when terms
      (typewhisper-api-add-terms terms))
    (quit-window t)
    (message "TypeWhisper: registered %d correction%s and %d term%s"
             (length corrections) (if (= (length corrections) 1) "" "s")
             (length terms) (if (= (length terms) 1) "" "s"))))

(defun typewhisper-register-discard ()
  "Close the registration buffer without registering anything."
  (interactive)
  (quit-window t)
  (message "TypeWhisper: nothing registered"))

;;;###autoload
(defun typewhisper-register-fixes (fixes &optional raw-text)
  "Let the user choose which FIXES to register in TypeWhisper.
FIXES is a list of plists with :wrong and :right.  RAW-TEXT is the
transcription before corrections, if known."
  (let* ((corrections (condition-case nil
                          (typewhisper-api-corrections)
                        (typewhisper-api-error nil)))
         (candidates (typewhisper-dictionary--make-candidates
                      fixes corrections raw-text))
         (buffer (get-buffer-create "*TypeWhisper Register*")))
    (with-current-buffer buffer
      (typewhisper-register-mode)
      (setq typewhisper-register--candidates candidates)
      (typewhisper-register--print)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    (message (substitute-command-keys
              "\\<typewhisper-register-mode-map>\\[typewhisper-register-commit] to register marked, \\[typewhisper-register-discard] to discard"))))

(provide 'typewhisper-dictionary)
;;; typewhisper-dictionary.el ends here
