;;; typewhisper-test.el --- Tests for typewhisper  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l ert -l test/typewhisper-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'typewhisper)

;;;; API

(ert-deftest typewhisper-test-api-quote ()
  (should (equal (typewhisper-api--quote "a\"b\\c\nd")
                 "\"a\\\"b\\\\c\\nd\"")))

(ert-deftest typewhisper-test-api-endpoint-from-discovery ()
  (let ((file (make-temp-file "tw-discovery" nil ".json"
                              "{\"port\": 9000, \"token\": \" secret \", \"version\": 1}")))
    (unwind-protect
        (let ((typewhisper-api-discovery-file file)
              (typewhisper-api-port nil)
              (typewhisper-api-token nil))
          (should (equal (typewhisper-api--endpoint) '(9000 . "secret"))))
      (delete-file file))))

(ert-deftest typewhisper-test-api-endpoint-defaults ()
  (let ((typewhisper-api-discovery-file "/nonexistent/api-discovery.json")
        (typewhisper-api-port nil)
        (typewhisper-api-token nil))
    (should (equal (typewhisper-api--endpoint) '(8978 . nil)))))

(ert-deftest typewhisper-test-api-build-config ()
  (let ((typewhisper-api-port 8978)
        (typewhisper-api-token "tok"))
    (let ((config (typewhisper-api--build-config
                   "PUT" "/v1/dictionary/corrections" '((q . "a b"))
                   '((original . "りあくと") (replacement . "React")))))
      (should (string-search "url = \"http://127.0.0.1:8978/v1/dictionary/corrections?q=a%20b\"" config))
      (should (string-search "request = \"PUT\"" config))
      (should (string-search "header = \"Authorization: Bearer tok\"" config))
      (should (string-search "data-binary = \"{\\\"original\\\":\\\"りあくと\\\"" config)))))

(ert-deftest typewhisper-test-api-build-config-no-token ()
  (let ((typewhisper-api-port 8978)
        (typewhisper-api-token nil)
        (typewhisper-api-discovery-file "/nonexistent"))
    (should-not (string-search "Authorization"
                               (typewhisper-api--build-config "GET" "/v1/status")))))

(ert-deftest typewhisper-test-api-handle-output ()
  (should (equal (typewhisper-api--handle-output 0 "{\"count\":1}\n200")
                 '((count . 1))))
  (should (null (typewhisper-api--handle-output 0 "\n204")))
  (let ((err (should-error (typewhisper-api--handle-output
                            0 "{\"error\":{\"code\":\"error\",\"message\":\"Not recording\"}}\n409")
                           :type 'typewhisper-api-error)))
    (should (equal (cadr err) "HTTP 409: Not recording")))
  (should-error (typewhisper-api--handle-output 7 "")
                :type 'typewhisper-api-error))

;;;; Prompt and parsing

(ert-deftest typewhisper-test-fix-context ()
  (with-temp-buffer
    (insert "l1\nl2\nl3 TARGET l3b\nl4\nl5\n")
    (let* ((start (progn (goto-char (point-min)) (search-forward "TARGET")
                         (match-beginning 0)))
           (end (match-end 0))
           (context (typewhisper-fix--context start end 1)))
      (should (equal (car context) "l2\nl3 "))
      (should (equal (cdr context) " l3b\nl4")))))

(ert-deftest typewhisper-test-fix-build-prompt ()
  (let ((prompt (typewhisper-fix--build-prompt
                 "りあくとで" "before" "after" 'markdown-mode
                 '("TypeWhisper")
                 '(((original . "ぷるりく") (replacement . "プルリク"))))))
    (should (string-search "markdown-mode" prompt))
    (should (string-search "<target>\nりあくとで\n</target>" prompt))
    (should (string-search "<before>\nbefore\n</before>" prompt))
    (should (string-search "<terms>\nTypeWhisper\n</terms>" prompt))
    (should (string-search "ぷるりく -> プルリク" prompt))))

(ert-deftest typewhisper-test-fix-command ()
  (let* ((typewhisper-claude-program "claude")
         (typewhisper-claude-model "sonnet")
         (typewhisper-claude-effort "low")
         (typewhisper-claude-extra-args nil)
         (cmd (typewhisper-fix--command "PROMPT")))
    (should (equal (car cmd) "claude"))
    (should (equal (car (last cmd)) "PROMPT"))
    (should (member "--json-schema" cmd))
    (should (equal (cadr (member "--model" cmd)) "sonnet"))
    (should (equal (cadr (member "--effort" cmd)) "low"))
    (should (equal (cadr (member "--tools" cmd)) ""))))

(ert-deftest typewhisper-test-fix-parse-output ()
  (let ((output "{\"type\":\"result\",\"is_error\":false,\"result\":\"...\",
\"structured_output\":{\"fixes\":[
 {\"wrong\":\"リアクト\",\"right\":\"React\",\"confidence\":\"high\"},
 {\"wrong\":\"same\",\"right\":\"same\",\"confidence\":\"high\"},
 {\"wrong\":\"ぷるりく\",\"right\":\"プルリク\",\"confidence\":\"low\"}]}}"))
    (should (equal (typewhisper-fix--parse-output output)
                   '((:wrong "リアクト" :right "React" :confidence high)
                     (:wrong "ぷるりく" :right "プルリク" :confidence low))))))

(ert-deftest typewhisper-test-fix-parse-output-from-result ()
  (should (equal (typewhisper-fix--parse-output
                  "{\"is_error\":false,\"result\":\"{\\\"fixes\\\":[]}\"}")
                 nil)))

(ert-deftest typewhisper-test-fix-parse-output-error ()
  (should-error (typewhisper-fix--parse-output
                 "{\"is_error\":true,\"result\":\"boom\"}"))
  (should-error (typewhisper-fix--parse-output "not json")))

;;;; Applying fixes

(defun typewhisper-test--apply (text target fixes &optional min)
  "Apply FIXES to TARGET inside TEXT.  Return (BUFFER-STRING APPLIED SUGGESTED)."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (search-forward target)
    (let* ((start (copy-marker (match-beginning 0)))
           (end (copy-marker (match-end 0) t))
           (result (typewhisper-fix--apply-fixes start end fixes (or min 'medium))))
      (list (buffer-string) (nth 0 result) (nth 1 result)))))

(ert-deftest typewhisper-test-apply-only-in-range ()
  (pcase-let ((`(,text ,applied ,_)
               (typewhisper-test--apply
                "リアクト before\nリアクトでユーズエフェクト\nafter リアクト"
                "リアクトでユーズエフェクト"
                '((:wrong "リアクト" :right "React" :confidence high)
                  (:wrong "ユーズエフェクト" :right "useEffect" :confidence medium)))))
    (should (equal text "リアクト before\nReactでuseEffect\nafter リアクト"))
    (should (= (length applied) 2))))

(ert-deftest typewhisper-test-apply-at-end-of-range ()
  (pcase-let ((`(,text ,_ ,_)
               (typewhisper-test--apply
                "xx ユーズエフェクト yy" "ユーズエフェクト"
                '((:wrong "ユーズエフェクト" :right "useEffect" :confidence high)
                  (:wrong "yy" :right "zz" :confidence high)))))
    (should (equal text "xx useEffect yy"))))

(ert-deftest typewhisper-test-apply-low-confidence-is-suggested ()
  (pcase-let ((`(,text ,applied ,suggested)
               (typewhisper-test--apply
                "ぷるりくを出す" "ぷるりくを出す"
                '((:wrong "ぷるりく" :right "プルリク" :confidence low)))))
    (should (equal text "ぷるりくを出す"))
    (should (null applied))
    (should (= (length suggested) 1))))

(ert-deftest typewhisper-test-apply-threshold ()
  (pcase-let ((`(,text ,_ ,_)
               (typewhisper-test--apply
                "ぷるりくを出す" "ぷるりくを出す"
                '((:wrong "ぷるりく" :right "プルリク" :confidence low))
                'low)))
    (should (equal text "プルリクを出す"))))

(ert-deftest typewhisper-test-apply-missing-wrong-dropped ()
  (pcase-let ((`(,_ ,applied ,suggested)
               (typewhisper-test--apply
                "abc" "abc"
                '((:wrong "xyz" :right "XYZ" :confidence high)
                  (:wrong "xyz" :right "XYZ" :confidence low)))))
    (should (null applied))
    (should (null suggested))))

(ert-deftest typewhisper-test-apply-case-sensitive ()
  (pcase-let ((`(,text ,_ ,_)
               (typewhisper-test--apply
                "React and react" "React and react"
                '((:wrong "react" :right "React" :confidence high)))))
    (should (equal text "React and React"))))

(ert-deftest typewhisper-test-finish-single-undo ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "リアクトでユーズエフェクト")
    (undo-boundary)
    (let ((typewhisper-fix-highlight-duration nil)
          (typewhisper-fix-confirm-registration nil))
      (typewhisper-fix--finish (current-buffer)
                               (copy-marker (point-min)) (copy-marker (point-max) t)
                               '((:wrong "リアクト" :right "React" :confidence high)
                                 (:wrong "ユーズエフェクト" :right "useEffect" :confidence high))
                               nil))
    (should (equal (buffer-string) "ReactでuseEffect"))
    (undo-boundary)
    (let ((last-command nil))
      (undo))
    (should (equal (buffer-string) "リアクトでユーズエフェクト"))))

;;;; Guards

(ert-deftest typewhisper-test-guard-short ()
  (should (assq 'block (typewhisper-dictionary-check "a" "A" nil)))
  (should (assq 'block (typewhisper-dictionary-check "てに" "手に" nil)))
  (should-not (assq 'block (typewhisper-dictionary-check "ぷるりく" "プルリク" nil)))
  (should-not (typewhisper-dictionary-check "リアクト" "React" nil)))

(ert-deftest typewhisper-test-guard-case-only ()
  (should (equal (car (typewhisper-dictionary-check "react" "React" nil))
                 '(warn . "differs only in case; check case sensitivity"))))

(ert-deftest typewhisper-test-guard-existing ()
  (let ((corrections '(((original . "リアクト") (replacement . "react"))
                       ((original . "ビュー") (replacement . "Vue")))))
    (should (equal (typewhisper-dictionary-check "リアクト" "React" corrections)
                   '((warn . "overwrites リアクト → react"))))
    (should (assq 'block (typewhisper-dictionary-check "ビュー" "Vue" corrections)))))

(ert-deftest typewhisper-test-guard-existing-ignores-case ()
  (let ((corrections '(((original . "React") (replacement . "React.js")))))
    (should (equal (typewhisper-dictionary-check "react" "React" corrections)
                   '((warn . "differs only in case; check case sensitivity")
                     (warn . "overwrites React → React.js")))))
  (let ((corrections '(((original . "Vue") (replacement . "Vue.js")))))
    (should (equal (typewhisper-dictionary-check "vue" "Vue.js" corrections)
                   '((warn . "overwrites Vue → Vue.js"))))))

(defun typewhisper-test--edit (old new)
  "Edit correction OLD to have original NEW.  Return the API calls made."
  (let (calls)
    (cl-letf (((symbol-function 'typewhisper-api-corrections)
               (lambda () '(((original . "React") (replacement . "React.js"))
                            ((original . "Vue") (replacement . "Vue.js")))))
              ((symbol-function 'typewhisper-corrections--read)
               (lambda (&rest _) (list new "React.js" nil)))
              ((symbol-function 'typewhisper-api-put-correction)
               (lambda (o &rest _) (push (list 'put o) calls)))
              ((symbol-function 'typewhisper-api-delete-correction)
               (lambda (o) (push (list 'delete o) calls)))
              ((symbol-function 'yes-or-no-p) #'always))
      (typewhisper-corrections)
      (with-current-buffer "*TypeWhisper Corrections*"
        (goto-char (point-min))
        (search-forward old)
        (typewhisper-corrections-edit)))
    (nreverse calls)))

(ert-deftest typewhisper-test-edit-case-only-does-not-delete ()
  (should (equal (typewhisper-test--edit "React" "react")
                 '((put "react")))))

(ert-deftest typewhisper-test-edit-rename-deletes-old ()
  (should (equal (typewhisper-test--edit "React" "Reakt")
                 '((put "Reakt") (delete "React")))))

(ert-deftest typewhisper-test-guard-raw-text ()
  (let ((corrections '(((original . "りあくと") (replacement . "リアクト")))))
    (should-not (typewhisper-dictionary-check "リアクト" "React" corrections "リアクトで"))
    (let ((issues (typewhisper-dictionary-check "リアクト" "React" corrections "りあくとで")))
      (should (assq 'block issues))
      (should (string-search "りあくと → リアクト" (cdr (assq 'block issues)))))))

(ert-deftest typewhisper-test-make-candidates ()
  (let ((candidates (typewhisper-dictionary--make-candidates
                     '((:wrong "リアクト" :right "React") (:wrong "て" :right "手"))
                     nil nil)))
    (should (plist-get (nth 0 candidates) :marked))
    (should-not (plist-get (nth 1 candidates) :marked))))

(ert-deftest typewhisper-test-register-commit ()
  (let (puts terms)
    (cl-letf (((symbol-function 'typewhisper-api-corrections) (lambda () nil))
              ((symbol-function 'typewhisper-api-put-correction)
               (lambda (o r c) (push (list o r c) puts)))
              ((symbol-function 'typewhisper-api-add-terms)
               (lambda (ts) (setq terms ts))))
      (typewhisper-register-fixes
       '((:wrong "リアクト" :right "React")
         (:wrong "ユーズエフェクト" :right "useEffect")
         (:wrong "て" :right "手")))
      (with-current-buffer "*TypeWhisper Register*"
        (goto-char (point-min))
        (forward-line 1)
        (typewhisper-register-toggle-type)
        (typewhisper-register-commit)))
    (should (equal puts '(("リアクト" "React" nil))))
    (should (equal terms '("useEffect")))))

;;;; Dictation

(ert-deftest typewhisper-test-find-pasted ()
  (with-temp-buffer
    (insert "foo ")
    (let ((marker (copy-marker (point))))
      (insert "hello world")
      (insert " bar")
      (should (equal (typewhisper--find-pasted marker "hello world") '(5 . 16)))
      (should-not (typewhisper--find-pasted marker "missing")))))

(ert-deftest typewhisper-test-find-pasted-moved-point ()
  (with-temp-buffer
    (insert "foo ")
    (let ((marker (copy-marker (point-min))))
      (insert "hello world")
      (should (equal (typewhisper--find-pasted marker "hello world") '(5 . 16))))))

(ert-deftest typewhisper-test-dictation-flow ()
  "Start, stop and record with the API mocked."
  (let ((typewhisper--state nil)
        (typewhisper--session nil)
        (typewhisper-last-dictation nil)
        (typewhisper-poll-interval 0)
        (typewhisper-paste-retry-interval 0)
        (polls 0))
    (cl-letf (((symbol-function 'typewhisper-api-dictation-start)
               (lambda (cb &rest _) (funcall cb '((id . "S1") (status . "recording")))))
              ((symbol-function 'typewhisper-api-dictation-stop)
               (lambda (cb &rest _) (funcall cb '((id . "S1") (status . "stopped")))))
              ((symbol-function 'typewhisper-api-dictation-transcription)
               (lambda (_id cb &rest _)
                 (cl-incf polls)
                 (funcall cb (if (< polls 2)
                                 '((status . "processing"))
                               '((status . "completed")
                                 (transcription (text . "React です")
                                                (raw_text . "リアクトです"))))))))
      (with-temp-buffer
        (insert "before ")
        (typewhisper-dictate)
        (should (eq typewhisper--state 'recording))
        (insert "React です")
        (typewhisper-dictate)
        (with-timeout (2 (error "Timed out"))
          (while (not typewhisper-last-dictation)
            (accept-process-output nil 0.01)))
        (should (null typewhisper--state))
        (pcase-let ((`(,buf ,start ,end ,raw) (typewhisper--last-dictation-range)))
          (should (eq buf (current-buffer)))
          (should (equal (buffer-substring start end) "React です"))
          (should (equal raw "リアクトです")))))))

(provide 'typewhisper-test)
;;; typewhisper-test.el ends here
