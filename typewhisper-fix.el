;;; typewhisper-fix.el --- Fix speech recognition errors with Claude  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 wakamenod

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Ask Claude (through the Claude Code CLI, `claude -p') which words in
;; a piece of dictated text were misrecognized, and replace them inside
;; that text only.  The surrounding lines are sent as context but are
;; never modified.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'typewhisper-api)

(declare-function typewhisper-register-fixes "typewhisper-dictionary")
(declare-function typewhisper--last-dictation-range "typewhisper")
(declare-function typewhisper--update-mode-line "typewhisper")

(defcustom typewhisper-claude-program "claude"
  "Name or path of the Claude Code CLI."
  :group 'typewhisper
  :type 'string)

(defcustom typewhisper-claude-model "sonnet"
  "Model passed to `claude --model'."
  :group 'typewhisper
  :type 'string)

(defcustom typewhisper-claude-effort "low"
  "Effort passed to `claude --effort'.  nil means do not pass it."
  :group 'typewhisper
  :type '(choice (const :tag "Default" nil) string))

(defcustom typewhisper-claude-extra-args nil
  "Extra arguments passed to `claude'."
  :group 'typewhisper
  :type '(repeat string))

(defcustom typewhisper-fix-context-lines 3
  "Number of lines before and after the target sent to Claude as context."
  :group 'typewhisper
  :type 'integer)

(defcustom typewhisper-fix-min-confidence 'medium
  "Lowest confidence at which a fix is applied.
Fixes below this level are only shown as suggestions."
  :group 'typewhisper
  :type '(choice (const high) (const medium) (const low)))

(defcustom typewhisper-fix-include-dictionary t
  "When non-nil, send the TypeWhisper terms and corrections to Claude."
  :group 'typewhisper
  :type 'boolean)

(defcustom typewhisper-fix-confirm-registration t
  "When non-nil, offer to register applied fixes as corrections."
  :group 'typewhisper
  :type 'boolean)

(defcustom typewhisper-fix-highlight-duration 3
  "Seconds to highlight replaced text.  nil means do not highlight."
  :group 'typewhisper
  :type '(choice (const :tag "No highlight" nil) number))

(defface typewhisper-fix-highlight
  '((t :inherit highlight))
  "Face for text replaced by `typewhisper-fix'."
  :group 'typewhisper)

(defvar typewhisper-fix--running 0
  "Number of `claude' processes currently running.")

(defconst typewhisper-fix-system-prompt
  "You fix speech recognition errors in dictated text.
The text is mostly Japanese and often contains English technical terms.

Rules:
- Fix only speech recognition errors. Do not change wording, word order, punctuation, or style.
- When an English technical term is written in katakana or hiragana, write it in its usual English form (for example ユーズエフェクト -> useEffect, リアクト -> React).
- Keep forms that are established in Japanese as they are (for example プルリク).
- The registered terms and corrections show how the user spells things. Prefer those spellings.
- Only the text inside <target> may be fixed. <before> and <after> are context only.
- Each `wrong` must be a string that appears exactly in <target>. Keep it as short as possible while still unambiguous.
- Use a lower confidence when you are not sure. If nothing needs fixing, return an empty `fixes` array."
  "System prompt for Claude.")

(defconst typewhisper-fix-json-schema
  '((type . "object")
    (properties
     . ((fixes
         . ((type . "array")
            (items
             . ((type . "object")
                (properties
                 . ((wrong . ((type . "string")))
                    (right . ((type . "string")))
                    (confidence . ((type . "string")
                                   (enum . ["high" "medium" "low"])))))
                (required . ["wrong" "right" "confidence"])
                (additionalProperties . :false)))))))
    (required . ["fixes"])
    (additionalProperties . :false))
  "JSON schema for Claude's answer.")

;;;; Prompt

(defun typewhisper-fix--context (start end lines)
  "Return (BEFORE . AFTER) context around START..END, LINES lines each way."
  (save-excursion
    (let ((before-start (progn (goto-char start)
                               (forward-line (- lines))
                               (point)))
          (after-end (progn (goto-char end)
                            (forward-line lines)
                            (line-end-position))))
      (cons (buffer-substring-no-properties before-start start)
            (buffer-substring-no-properties end after-end)))))

(defun typewhisper-fix--format-dictionary (terms corrections)
  "Format TERMS and CORRECTIONS for the prompt."
  (concat
   (when terms
     (concat "<terms>\n" (string-join terms "\n") "\n</terms>\n"))
   (when corrections
     (concat "<corrections>\n"
             (mapconcat (lambda (c)
                          (let-alist c (format "%s -> %s" .original .replacement)))
                        corrections "\n")
             "\n</corrections>\n"))))

(defun typewhisper-fix--build-prompt (target before after mode terms corrections)
  "Build the user prompt.
TARGET is the text to fix, BEFORE and AFTER are context.  MODE is the
major mode of the buffer.  TERMS and CORRECTIONS come from TypeWhisper."
  (concat
   (format "The text is in an Emacs buffer in %s.\n\n" mode)
   (typewhisper-fix--format-dictionary terms corrections)
   "<before>\n" before "\n</before>\n"
   "<target>\n" target "\n</target>\n"
   "<after>\n" after "\n</after>\n"))

(defun typewhisper-fix--command (prompt)
  "Return the `claude' command line for PROMPT."
  (append
   (list typewhisper-claude-program "-p"
         "--model" typewhisper-claude-model)
   (and typewhisper-claude-effort (list "--effort" typewhisper-claude-effort))
   (list "--tools" ""
         "--strict-mcp-config"
         "--disable-slash-commands"
         "--setting-sources" ""
         "--no-session-persistence"
         "--system-prompt" typewhisper-fix-system-prompt
         "--output-format" "json"
         "--json-schema" (json-serialize typewhisper-fix-json-schema))
   typewhisper-claude-extra-args
   (list prompt)))

;;;; Parsing

(defun typewhisper-fix--parse-output (output)
  "Parse the JSON OUTPUT of `claude -p'.
Return a list of plists with :wrong, :right and :confidence (a symbol).
Signal an error if Claude reported one."
  (let ((data (condition-case nil
                  (json-parse-string (string-trim output)
                                     :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil)
                (error (error "Cannot parse claude output: %s"
                              (truncate-string-to-width (string-trim output) 200))))))
    (let-alist data
      (when .is_error
        (error "Claude returned an error: %s" (or .result "unknown")))
      (let ((structured (or .structured_output
                            (and (stringp .result)
                                 (ignore-errors
                                   (json-parse-string .result
                                                      :object-type 'alist
                                                      :array-type 'list))))))
        (delq nil
              (mapcar (lambda (fix)
                        (let-alist fix
                          (when (and (stringp .wrong) (stringp .right)
                                     (not (string-empty-p .wrong))
                                     (not (equal .wrong .right)))
                            (list :wrong .wrong :right .right
                                  :confidence (intern (or .confidence "low"))))))
                      (alist-get 'fixes structured)))))))

;;;; Applying

(defun typewhisper-fix--confidence-rank (confidence)
  "Return a number for CONFIDENCE so that higher is more confident."
  (pcase confidence ('high 3) ('medium 2) ('low 1) (_ 0)))

(defun typewhisper-fix--apply-fixes (start end fixes min-confidence)
  "Apply FIXES between markers START and END in the current buffer.
Only fixes at MIN-CONFIDENCE or above are applied.  Text outside the
range is never changed.  Return (APPLIED SUGGESTED OVERLAYS): the
fixes that were applied, the fixes that were only suggested, and the
overlays on replaced text.  Fixes whose `wrong' is not in the range
are dropped."
  (let ((applied nil) (suggested nil) (overlays nil)
        (case-fold-search nil)
        (threshold (typewhisper-fix--confidence-rank min-confidence)))
    (save-excursion
      (dolist (fix fixes)
        (let ((wrong (plist-get fix :wrong))
              (right (plist-get fix :right))
              (found nil))
          (goto-char start)
          (if (< (typewhisper-fix--confidence-rank (plist-get fix :confidence))
                 threshold)
              (when (search-forward wrong end t)
                (push fix suggested))
            (while (search-forward wrong end t)
              (setq found t)
              (let ((beg (match-beginning 0)))
                (replace-match right t t)
                (push (make-overlay beg (point)) overlays)))
            (when found (push fix applied))))))
    (list (nreverse applied) (nreverse suggested) overlays)))

(defun typewhisper-fix--highlight (overlays)
  "Highlight OVERLAYS for a while, then delete them."
  (if (not typewhisper-fix-highlight-duration)
      (mapc #'delete-overlay overlays)
    (dolist (ov overlays)
      (overlay-put ov 'face 'typewhisper-fix-highlight))
    (run-with-timer typewhisper-fix-highlight-duration nil
                    (lambda () (mapc #'delete-overlay overlays)))))

(defun typewhisper-fix--format-fix (fix)
  "Format FIX for a message."
  (format "%s → %s" (plist-get fix :wrong) (plist-get fix :right)))

(defun typewhisper-fix--report (applied suggested)
  "Show a message about APPLIED and SUGGESTED fixes."
  (message "TypeWhisper: %s%s"
           (if applied
               (format "%d fix%s applied (%s)" (length applied)
                       (if (cdr applied) "es" "")
                       (mapconcat #'typewhisper-fix--format-fix applied ", "))
             "No fixes applied")
           (if suggested
               (format "; suggestions: %s"
                       (mapconcat #'typewhisper-fix--format-fix suggested ", "))
             "")))

(defun typewhisper-fix--finish (buffer start end fixes raw-text)
  "Apply FIXES between markers START and END in BUFFER.
RAW-TEXT is TypeWhisper's raw transcription, or nil."
  (with-current-buffer buffer
    (let ((group (prepare-change-group))
          result)
      (unwind-protect
          (progn
            (activate-change-group group)
            (setq result (typewhisper-fix--apply-fixes
                          start end fixes typewhisper-fix-min-confidence)))
        (accept-change-group group)
        (undo-amalgamate-change-group group))
      (pcase-let ((`(,applied ,suggested ,overlays) result))
        (typewhisper-fix--highlight overlays)
        (typewhisper-fix--report applied suggested)
        (when (and applied typewhisper-fix-confirm-registration)
          (require 'typewhisper-dictionary)
          (typewhisper-register-fixes applied raw-text))))))

;;;; Running Claude

(defun typewhisper-fix--dictionary ()
  "Return (TERMS . CORRECTIONS) from TypeWhisper, or nil if unavailable."
  (when typewhisper-fix-include-dictionary
    (condition-case nil
        (let ((typewhisper-api-timeout 3))
          (cons (typewhisper-api-terms) (typewhisper-api-corrections)))
      (typewhisper-api-error nil))))

(defun typewhisper-fix--set-running (delta)
  "Change the count of running fixes by DELTA and update the mode line."
  (setq typewhisper-fix--running (max 0 (+ typewhisper-fix--running delta)))
  (when (fboundp 'typewhisper--update-mode-line)
    (typewhisper--update-mode-line)))

(defun typewhisper-fix-range (start end &optional raw-text)
  "Fix speech recognition errors between START and END.
START and END are positions or markers in the current buffer.
RAW-TEXT is TypeWhisper's raw transcription of that text, if known.
Claude runs asynchronously; the buffer may be edited meanwhile."
  (let* ((buffer (current-buffer))
         (start (copy-marker start))
         (end (copy-marker end t))
         (target (buffer-substring-no-properties start end))
         (context (typewhisper-fix--context start end typewhisper-fix-context-lines))
         (dictionary (typewhisper-fix--dictionary))
         (prompt (typewhisper-fix--build-prompt
                  target (car context) (cdr context) major-mode
                  (car dictionary) (cdr dictionary)))
         (out (generate-new-buffer " *typewhisper-claude*"))
         (err (generate-new-buffer " *typewhisper-claude-stderr*")))
    (when (string-empty-p (string-trim target))
      (user-error "Nothing to fix"))
    (typewhisper-fix--set-running 1)
    (message "TypeWhisper: asking Claude...")
    (let ((proc
           (make-process
            :name "typewhisper-claude"
            :buffer out
            :stderr err
            :command (typewhisper-fix--command prompt)
            :connection-type 'pipe
            :coding 'utf-8-unix
            :noquery t
            :sentinel
            (lambda (proc _event)
              (unless (process-live-p proc)
                (typewhisper-fix--set-running -1)
                (let ((output (with-current-buffer out (buffer-string)))
                      (stderr (with-current-buffer err (buffer-string)))
                      (exit (process-exit-status proc)))
                  (kill-buffer out)
                  (kill-buffer err)
                  (condition-case e
                      (cond
                       ((not (buffer-live-p buffer))
                        (message "TypeWhisper: buffer was killed; fixes discarded"))
                       ((and (not (eq exit 0)) (string-empty-p (string-trim output)))
                        (error "Claude exited with %s: %s" exit (string-trim stderr)))
                       (t
                        (typewhisper-fix--finish
                         buffer start end
                         (typewhisper-fix--parse-output output)
                         raw-text)))
                    (error (message "TypeWhisper: %s" (error-message-string e))))))))))
      (process-send-eof proc)
      proc)))

;;;###autoload
(defun typewhisper-fix ()
  "Fix speech recognition errors with Claude.
Fix the active region, or else the text of the last dictation."
  (interactive)
  (if (use-region-p)
      (typewhisper-fix-range (region-beginning) (region-end))
    (pcase (and (fboundp 'typewhisper--last-dictation-range)
                (typewhisper--last-dictation-range))
      (`(,buffer ,start ,end ,raw-text)
       (with-current-buffer buffer
         (typewhisper-fix-range start end raw-text)))
      (_ (user-error "No region and no recent dictation to fix")))))

(provide 'typewhisper-fix)
;;; typewhisper-fix.el ends here
