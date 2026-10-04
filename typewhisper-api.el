;;; typewhisper-api.el --- HTTP API client for TypeWhisper  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 wakamenod

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A small client for the local HTTP API of TypeWhisper
;; (https://github.com/TypeWhisper/typewhisper-mac).
;;
;; Requests are sent with curl.  The request (including the bearer
;; token and the JSON body) is passed to curl as a config file on
;; stdin, so the token never shows up in the process list.
;;
;; The port and token are read from TypeWhisper's discovery file
;; unless `typewhisper-api-port' or `typewhisper-api-token' is set.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'url-util)

(defgroup typewhisper nil
  "Control TypeWhisper dictation and its dictionary from Emacs."
  :group 'tools
  :prefix "typewhisper-")

(defcustom typewhisper-api-host "127.0.0.1"
  "Host of the TypeWhisper API server."
  :group 'typewhisper
  :type 'string)

(defcustom typewhisper-api-port nil
  "Port of the TypeWhisper API server.
When nil, read it from `typewhisper-api-discovery-file', falling
back to 8978."
  :group 'typewhisper
  :type '(choice (const :tag "Discover" nil) integer))

(defcustom typewhisper-api-token nil
  "Bearer token for the TypeWhisper API.
When nil, read it from `typewhisper-api-discovery-file'."
  :group 'typewhisper
  :type '(choice (const :tag "Discover" nil) string))

(defcustom typewhisper-api-discovery-file
  "~/Library/Application Support/TypeWhisper/api-discovery.json"
  "File where TypeWhisper writes the API port and token while the server runs."
  :group 'typewhisper
  :type 'file)

(defcustom typewhisper-curl-program "curl"
  "Name or path of the curl executable."
  :group 'typewhisper
  :type 'string)

(defcustom typewhisper-api-timeout 10
  "Default timeout in seconds for API requests."
  :group 'typewhisper
  :type 'integer)

(defconst typewhisper-api-default-port 8978
  "Port TypeWhisper uses when nothing else is configured.")

(define-error 'typewhisper-api-error "TypeWhisper API error")

;;;; Discovery

(defun typewhisper-api--read-discovery ()
  "Return the parsed discovery file as an alist, or nil."
  (let ((file (expand-file-name typewhisper-api-discovery-file)))
    (when (file-readable-p file)
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (json-parse-buffer :object-type 'alist :null-object nil))
        (error nil)))))

(defun typewhisper-api--endpoint ()
  "Return (PORT . TOKEN) for the API server.  TOKEN may be nil."
  (let* ((discovery (and (not (and typewhisper-api-port typewhisper-api-token))
                         (typewhisper-api--read-discovery)))
         (port (or typewhisper-api-port
                   (let ((p (alist-get 'port discovery)))
                     (and (integerp p) (> p 0) p))
                   typewhisper-api-default-port))
         (token (or typewhisper-api-token
                    (let ((tk (alist-get 'token discovery)))
                      (and (stringp tk)
                           (not (string-empty-p (string-trim tk)))
                           (string-trim tk))))))
    (cons port token)))

;;;; Request building

(defun typewhisper-api--json (object)
  "Serialize OBJECT to a JSON string of characters, not bytes."
  (let ((json (json-serialize object)))
    (if (multibyte-string-p json)
        json
      (decode-coding-string json 'utf-8))))

(defun typewhisper-api--quote (string)
  "Quote STRING for a curl config file."
  (concat "\""
          (replace-regexp-in-string
           "[\\\"\n\r\t]"
           (lambda (c)
             (pcase c
               ("\n" "\\n") ("\r" "\\r") ("\t" "\\t")
               (_ (concat "\\" c))))
           string t t)
          "\""))

(defun typewhisper-api--query-string (query)
  "Encode QUERY, an alist of (KEY . VALUE), as a URL query string."
  (mapconcat (lambda (pair)
               (concat (url-hexify-string (format "%s" (car pair)))
                       "="
                       (url-hexify-string (format "%s" (cdr pair)))))
             query "&"))

(defun typewhisper-api--build-config (method path &optional query body timeout)
  "Return a curl config string for a request.
METHOD is an HTTP method string, PATH starts with /v1/.  QUERY is an
alist of query parameters.  BODY is a Lisp object serialized with
`json-serialize'.  TIMEOUT is in seconds."
  (pcase-let* ((`(,port . ,token) (typewhisper-api--endpoint))
               (url (format "http://%s:%d%s%s" typewhisper-api-host port path
                            (if query
                                (concat "?" (typewhisper-api--query-string query))
                              ""))))
    (string-join
     (delq nil
           (list "silent" "show-error"
                 (concat "url = " (typewhisper-api--quote url))
                 (concat "request = " (typewhisper-api--quote method))
                 (format "max-time = %d" (or timeout typewhisper-api-timeout))
                 (concat "write-out = " (typewhisper-api--quote "\n%{http_code}"))
                 (and token
                      (concat "header = "
                              (typewhisper-api--quote
                               (concat "Authorization: Bearer " token))))
                 (and body
                      (concat "header = "
                              (typewhisper-api--quote "Content-Type: application/json")))
                 (and body
                      (concat "data-binary = "
                              (typewhisper-api--quote (typewhisper-api--json body))))))
     "\n")))

;;;; Response parsing

(defun typewhisper-api--parse-json (string)
  "Parse STRING as JSON.  Return nil for an empty string."
  (unless (string-empty-p (string-trim string))
    (json-parse-string string :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defun typewhisper-api--handle-output (exit-code output)
  "Turn curl's EXIT-CODE and OUTPUT into parsed JSON or signal an error."
  (cond
   ((eq exit-code 7)
    (signal 'typewhisper-api-error
            (list "Cannot connect to TypeWhisper. Is the API server enabled in Settings > Advanced?")))
   ((not (eq exit-code 0))
    (signal 'typewhisper-api-error
            (list (format "curl failed (%s): %s" exit-code (string-trim output)))))
   ((not (string-match "\n\\([0-9]+\\)\\'" output))
    (signal 'typewhisper-api-error (list "Unexpected response from curl")))
   (t
    (let* ((status (string-to-number (match-string 1 output)))
           (body (substring output 0 (match-beginning 0)))
           (data (condition-case nil
                     (typewhisper-api--parse-json body)
                   (error nil))))
      (if (<= 200 status 299)
          data
        (signal 'typewhisper-api-error
                (list (format "HTTP %d: %s" status
                              (or (let-alist data .error.message)
                                  (string-trim body)))
                      status)))))))

;;;; Sending

(defun typewhisper-api-request-sync (method path &rest args)
  "Send a request and return the parsed JSON response.
METHOD and PATH are as in `typewhisper-api--build-config'.  ARGS is a
plist with :query, :body and :timeout.  Signal `typewhisper-api-error'
on failure."
  (let ((config (typewhisper-api--build-config
                 method path (plist-get args :query) (plist-get args :body)
                 (plist-get args :timeout))))
    (with-temp-buffer
      (let* ((coding-system-for-write 'utf-8-unix)
             (coding-system-for-read 'utf-8-unix)
             (exit (call-process-region config nil typewhisper-curl-program
                                        nil t nil "--config" "-")))
        (typewhisper-api--handle-output exit (buffer-string))))))

(defun typewhisper-api-request (method path callback &rest args)
  "Send a request asynchronously.
METHOD and PATH are as in `typewhisper-api--build-config'.  CALLBACK
is called with the parsed JSON response.  ARGS is a plist with :query,
:body, :timeout and :error.  The :error function is called with the
error message; it defaults to showing the message in the echo area.
Return the curl process."
  (let* ((config (typewhisper-api--build-config
                  method path (plist-get args :query) (plist-get args :body)
                  (plist-get args :timeout)))
         (on-error (or (plist-get args :error)
                       (lambda (msg) (message "TypeWhisper: %s" msg))))
         (buffer (generate-new-buffer " *typewhisper-api*"))
         (proc (make-process
                :name "typewhisper-api"
                :buffer buffer
                :command (list typewhisper-curl-program "--config" "-")
                :connection-type 'pipe
                :coding 'utf-8-unix
                :noquery t
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (let ((output (with-current-buffer (process-buffer proc)
                                    (buffer-string)))
                          (exit (process-exit-status proc)))
                      (kill-buffer (process-buffer proc))
                      (pcase (condition-case err
                                 (cons 'ok (typewhisper-api--handle-output exit output))
                               (typewhisper-api-error (cons 'error (cadr err))))
                        (`(ok . ,data) (funcall callback data))
                        (`(error . ,msg) (funcall on-error msg)))))))))
    (process-send-string proc config)
    (process-send-eof proc)
    proc))

;;;; Endpoints: dictation

(defun typewhisper-api-dictation-start (callback &rest args)
  "Start dictation and call CALLBACK with the response.
The server answers only when the microphone is ready.  ARGS may
contain :workflow-id and :error."
  (let ((workflow (plist-get args :workflow-id)))
    (typewhisper-api-request
     "POST" "/v1/dictation/start" callback
     :body (and workflow `((workflow_id . ,workflow)))
     :timeout 60
     :error (plist-get args :error))))

(defun typewhisper-api-dictation-stop (callback &rest args)
  "Stop dictation and call CALLBACK with the response.
ARGS may contain :error."
  (typewhisper-api-request "POST" "/v1/dictation/stop" callback
                           :error (plist-get args :error)))

(defun typewhisper-api-dictation-status (callback &rest args)
  "Call CALLBACK with the dictation status.  ARGS may contain :error."
  (typewhisper-api-request "GET" "/v1/dictation/status" callback
                           :error (plist-get args :error)))

(defun typewhisper-api-dictation-transcription (id callback &rest args)
  "Call CALLBACK with the state of dictation session ID.
ARGS may contain :error."
  (typewhisper-api-request "GET" "/v1/dictation/transcription" callback
                           :query `((id . ,id))
                           :error (plist-get args :error)))

;;;; Endpoints: dictionary

(defun typewhisper-api-corrections ()
  "Return the list of corrections.
Each element is an alist with `original', `replacement' and
`caseSensitive'."
  (alist-get 'corrections
             (typewhisper-api-request-sync "GET" "/v1/dictionary/corrections")))

(defun typewhisper-api-put-correction (original replacement &optional case-sensitive)
  "Add or update the correction for ORIGINAL to REPLACEMENT.
CASE-SENSITIVE non-nil makes the match case sensitive."
  (typewhisper-api-request-sync
   "PUT" "/v1/dictionary/corrections"
   :body `((original . ,original)
           (replacement . ,replacement)
           (caseSensitive . ,(if case-sensitive t :false)))))

(defun typewhisper-api-delete-correction (original)
  "Delete the correction for ORIGINAL."
  (typewhisper-api-request-sync "DELETE" "/v1/dictionary/corrections"
                                :body `((original . ,original))))

(defun typewhisper-api-terms ()
  "Return the list of dictionary terms (strings)."
  (alist-get 'terms (typewhisper-api-request-sync "GET" "/v1/dictionary/terms")))

(defun typewhisper-api-add-terms (terms)
  "Add TERMS, a list of strings, to the dictionary."
  (typewhisper-api-request-sync "PUT" "/v1/dictionary/terms"
                                :body `((terms . ,(vconcat terms))
                                        (replace . :false))))

(defun typewhisper-api-delete-term (term)
  "Delete TERM from the dictionary."
  (typewhisper-api-request-sync "DELETE" "/v1/dictionary/terms"
                                :body `((term . ,term))))

(provide 'typewhisper-api)
;;; typewhisper-api.el ends here
