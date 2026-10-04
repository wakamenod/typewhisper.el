;;; typewhisper.el --- Dictate with TypeWhisper and fix errors with Claude  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 wakamenod

;; Author: wakamenod
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/wakamenod/typewhisper.el

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Control TypeWhisper (a macOS dictation app) from Emacs, fix
;; misrecognized words with Claude, and register those fixes in the
;; TypeWhisper dictionary so they do not happen again.
;;
;; Main commands:
;;
;; - `typewhisper-dictate': start or stop dictation.
;; - `typewhisper-dictate-and-fix': the same, then fix the result.
;; - `typewhisper-fix': fix the region or the last dictation.
;; - `typewhisper-corrections', `typewhisper-terms': edit the dictionary.
;;
;; `typewhisper-mode' shows the dictation state in the mode line.

;;; Code:

(require 'cl-lib)
(require 'typewhisper-api)
(require 'typewhisper-fix)
(require 'typewhisper-dictionary)

(defcustom typewhisper-poll-interval 0.3
  "Seconds between polls for the transcription result."
  :group 'typewhisper
  :type 'number)

(defcustom typewhisper-transcription-timeout 120
  "Seconds to wait for a transcription after dictation stops."
  :group 'typewhisper
  :type 'number)

(defcustom typewhisper-paste-retries 10
  "How many times to look for the pasted text before giving up."
  :group 'typewhisper
  :type 'integer)

(defcustom typewhisper-paste-retry-interval 0.2
  "Seconds between checks for the pasted text."
  :group 'typewhisper
  :type 'number)

(defcustom typewhisper-workflow-id nil
  "Workflow ID passed when starting dictation, or nil for the default."
  :group 'typewhisper
  :type '(choice (const :tag "Default" nil) string))

;;;; State

(defvar typewhisper--state nil
  "Dictation state: nil, `starting', `recording' or `transcribing'.")

(defvar typewhisper--session nil
  "Plist for the current dictation.
Keys: :id, :buffer, :marker, :fix.")

(cl-defstruct (typewhisper-dictation (:constructor typewhisper-dictation-create))
  "The text inserted by the last dictation."
  id buffer start end text raw-text)

(defvar typewhisper-last-dictation nil
  "The last dictation, a `typewhisper-dictation', or nil.")

(defun typewhisper--set-state (state)
  "Set the dictation STATE and update the mode line."
  (setq typewhisper--state state)
  (typewhisper--update-mode-line))

(defun typewhisper--reset ()
  "Forget the current dictation session."
  (when-let* ((marker (plist-get typewhisper--session :marker)))
    (set-marker marker nil))
  (setq typewhisper--session nil)
  (typewhisper--set-state nil))

(defun typewhisper--last-dictation-range ()
  "Return (BUFFER START END RAW-TEXT) for the last dictation, or nil."
  (when-let* ((d typewhisper-last-dictation)
              (buffer (typewhisper-dictation-buffer d))
              ((buffer-live-p buffer))
              (start (typewhisper-dictation-start d))
              (end (typewhisper-dictation-end d))
              ((eq (marker-buffer start) buffer))
              ((< start end)))
    (list buffer start end (typewhisper-dictation-raw-text d))))

;;;; Locating the pasted text

(defun typewhisper--find-pasted (marker text)
  "Return (START . END) of TEXT pasted at MARKER, or nil.
Look at MARKER first, then near point in case point moved."
  (with-current-buffer (marker-buffer marker)
    (let ((len (length text))
          (pos (marker-position marker)))
      (cond
       ((string-empty-p text) nil)
       ((and (<= (+ pos len) (point-max))
             (equal (buffer-substring-no-properties pos (+ pos len)) text))
        (cons pos (+ pos len)))
       (t
        (save-excursion
          (let ((case-fold-search nil)
                (here (point)))
            (goto-char (min (point-max) (+ here len)))
            (when (search-backward text (max (point-min) (- here len len)) t)
              (cons (match-beginning 0) (match-end 0))))))))))

(defun typewhisper--record (id buffer marker text raw-text tries callback)
  "Record the dictation once TEXT shows up at MARKER in BUFFER.
ID is the session id and RAW-TEXT the uncorrected text.  Retry TRIES
more times, then call CALLBACK with the recorded dictation or nil."
  (let ((range (and (buffer-live-p buffer)
                    (typewhisper--find-pasted marker text))))
    (cond
     (range
      (with-current-buffer buffer
        (setq typewhisper-last-dictation
              (typewhisper-dictation-create
               :id id :buffer buffer
               :start (copy-marker (car range))
               :end (copy-marker (cdr range) t)
               :text text :raw-text raw-text)))
      (set-marker marker nil)
      (funcall callback typewhisper-last-dictation))
     ((and (> tries 0) (buffer-live-p buffer))
      (run-with-timer typewhisper-paste-retry-interval nil
                      #'typewhisper--record
                      id buffer marker text raw-text (1- tries) callback))
     (t
      (set-marker marker nil)
      (funcall callback nil)))))

;;;; Polling

(defun typewhisper--poll (session deadline)
  "Poll the transcription for SESSION until it finishes or DEADLINE passes."
  (let ((id (plist-get session :id)))
    (typewhisper-api-dictation-transcription
     id
     (lambda (data)
       (let-alist data
         (pcase .status
           ("completed"
            (typewhisper--on-transcribed session .transcription.text
                                         .transcription.raw_text))
           ("failed"
            (typewhisper--reset)
            (message "TypeWhisper: transcription failed: %s" (or .error "unknown error")))
           (_
            (if (> (float-time) deadline)
                (progn (typewhisper--reset)
                       (message "TypeWhisper: timed out waiting for the transcription"))
              (run-with-timer typewhisper-poll-interval nil
                              #'typewhisper--poll session deadline))))))
     :error (lambda (msg)
              (typewhisper--reset)
              (message "TypeWhisper: %s" msg)))))

(defun typewhisper--on-transcribed (session text raw-text)
  "Handle a finished transcription of SESSION with TEXT and RAW-TEXT."
  (setq typewhisper--session nil)
  (typewhisper--set-state nil)
  (if (or (null text) (string-empty-p text))
      (progn (set-marker (plist-get session :marker) nil)
             (message "TypeWhisper: nothing was recognized"))
    (typewhisper--record
     (plist-get session :id) (plist-get session :buffer)
     (plist-get session :marker) text raw-text typewhisper-paste-retries
     (lambda (dictation)
       (cond
        ((null dictation)
         (message "TypeWhisper: transcribed, but the pasted text was not found"))
        ((plist-get session :fix)
         (with-current-buffer (typewhisper-dictation-buffer dictation)
           (typewhisper-fix-range (typewhisper-dictation-start dictation)
                                  (typewhisper-dictation-end dictation)
                                  (typewhisper-dictation-raw-text dictation))))
        (t (message "TypeWhisper: %s" text)))))))

;;;; Commands

(defun typewhisper--start (fix)
  "Start dictation at point.  FIX non-nil fixes the result afterwards."
  (let ((session (list :id nil
                       :buffer (current-buffer)
                       :marker (copy-marker (point))
                       :fix fix)))
    (setq typewhisper--session session)
    (typewhisper--set-state 'starting)
    (message "TypeWhisper: starting...")
    (typewhisper-api-dictation-start
     (lambda (data)
       (if (not (eq typewhisper--session session))
           ;; Cancelled while the microphone was getting ready.
           nil
         (plist-put session :id (alist-get 'id data))
         (typewhisper--set-state 'recording)
         (message "TypeWhisper: recording... (%s to stop)"
                  (substitute-command-keys
                   (if fix "\\[typewhisper-dictate-and-fix]" "\\[typewhisper-dictate]")))))
     :workflow-id typewhisper-workflow-id
     :error (lambda (msg)
              (when (eq typewhisper--session session)
                (typewhisper--reset))
              (message "TypeWhisper: %s" msg)))))

(defun typewhisper--stop (fix)
  "Stop dictation.  FIX non-nil fixes the result afterwards."
  (let ((session typewhisper--session))
    (when fix (plist-put session :fix t))
    (typewhisper--set-state 'transcribing)
    (typewhisper-api-dictation-stop
     (lambda (data)
       (unless (plist-get session :id)
         (plist-put session :id (alist-get 'id data)))
       (typewhisper--poll session (+ (float-time) typewhisper-transcription-timeout)))
     :error (lambda (msg)
              (typewhisper--reset)
              (message "TypeWhisper: %s" msg)))))

(defun typewhisper--toggle (fix)
  "Start or stop dictation.  FIX non-nil fixes the result afterwards."
  (pcase typewhisper--state
    ('nil (typewhisper--start fix))
    ('recording (typewhisper--stop fix))
    ('starting (message "TypeWhisper: still starting; try again in a moment"))
    ('transcribing (message "TypeWhisper: still transcribing"))))

;;;###autoload
(defun typewhisper-dictate ()
  "Start dictation at point, or stop it if it is running.
TypeWhisper pastes the result into the frontmost app, so keep Emacs
in front.  The pasted text is remembered for `typewhisper-fix'."
  (interactive)
  (typewhisper--toggle nil))

;;;###autoload
(defun typewhisper-dictate-and-fix ()
  "Like `typewhisper-dictate', but fix the result with Claude."
  (interactive)
  (typewhisper--toggle t))

;;;###autoload
(defun typewhisper-cancel ()
  "Forget the current dictation state.
Use this when the state in Emacs got out of sync with TypeWhisper."
  (interactive)
  (typewhisper--reset)
  (message "TypeWhisper: state reset"))

;;;; Mode line

(defun typewhisper--mode-line ()
  "Return the mode line string for `typewhisper-mode'."
  (concat
   " TW"
   (pcase typewhisper--state
     ('starting "[…]")
     ('recording (propertize "[REC]" 'face 'error))
     ('transcribing "[…]")
     (_ ""))
   (if (> typewhisper-fix--running 0) "[fix]" "")))

(defun typewhisper--update-mode-line ()
  "Refresh the mode line."
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode typewhisper-mode
  "Show the TypeWhisper dictation state in the mode line."
  :global t
  :group 'typewhisper
  :lighter (:eval (typewhisper--mode-line)))

(provide 'typewhisper)
;;; typewhisper.el ends here
