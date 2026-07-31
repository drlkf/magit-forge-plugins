;;; forge-plugins-github-actions-test.el --- Tests for the GitHub Actions plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; Assert the forge API surface the plugin depends on, so the build fails
;; when an upstream forge change renames or removes a symbol or slot.

;;; Code:

(require 'ert)
(require 'forge)
(require 'forge-pullreq)
(require 'forge-plugins-github-actions)
(require 'forge-plugins-log)

(ert-deftest forge-plugins-github-actions-test-rerun-url ()
  "Build the Actions job rerun endpoint from a job URL."
  (should (equal
           (forge-plugins-github-actions--rerun-url
            '((html_url . "https://github.com/o/r/actions/runs/12/job/34")))
           "/repos/:owner/:repo/actions/jobs/34/rerun")))

(ert-deftest forge-plugins-github-actions-test-rerun-url-without-job ()
  "Do not build a rerun endpoint when no job ID is available."
  (should-not (forge-plugins-github-actions--rerun-url '((id . 34)))))

(ert-deftest forge-plugins-log-test-error-message ()
  "Extract the API message from a ghub HTTP error."
  (should (equal
           (forge-plugins-log-error-message
            '(error http 403 ((message . "Forbidden"))))
           "Forbidden")))

(ert-deftest forge-plugins-github-actions-test-forge-api-surface ()
  "The forge symbols and slots the plugin relies on must exist."
  (should (fboundp 'forge--format-topic-line))
  (should (fboundp 'forge-insert-post))
  (should (fboundp 'forge--rest))
  (should (macrop 'forge-rest))
  (should (cl-find 'head-rev (eieio-class-slots 'forge-pullreq)
                   :key #'eieio-slot-descriptor-name)))

(ert-deftest forge-plugins-github-actions-test-patch-line-idempotent ()
  "Patching a topic line twice replaces the badge, never duplicates it."
  (let* ((topic (forge-pullreq :id "T1" :head-rev "abc"))
         (forge-plugins-github-actions--cache (make-hash-table :test 'equal)))
    (puthash "T1" (list :head-rev "abc" :total 2 :success 1 :failure 0
                        :skipped 0 :fetching nil)
             forge-plugins-github-actions--cache)
    (with-temp-buffer
      (insert "topic line\n")
      (let ((section (magit-section :type 'topic)))
        (oset section value topic)
        (oset section start (copy-marker (point-min)))
        (forge-plugins-github-actions--patch-line-badge section topic)
        (goto-char (point-min))
        (should (re-search-forward "(1/2)" (line-end-position) t))
        (let ((after-first (buffer-string)))
          ;; Re-patching with the same cache must not append a second badge.
          (forge-plugins-github-actions--patch-line-badge section topic)
          (should (equal (buffer-string) after-first))
          (goto-char (point-min))
          (should-not (re-search-forward "(1/2).*(1/2)" nil t)))))))

(ert-deftest forge-plugins-github-actions-test-flush-batches ()
  "A single flush patches every pending topic in one tree walk."
  (let* ((t1 (forge-pullreq :id "T1" :head-rev "a"))
         (t2 (forge-pullreq :id "T2" :head-rev "b"))
         (forge-plugins-github-actions--cache (make-hash-table :test 'equal))
         (forge-plugins-github-actions--pending (make-hash-table :test 'equal))
         (forge-plugins-github-actions--flush-timer nil))
    (puthash "T1" (list :head-rev "a" :total 2 :success 2 :failure 0
                        :skipped 0 :fetching nil)
             forge-plugins-github-actions--cache)
    (puthash "T2" (list :head-rev "b" :total 3 :success 1 :failure 0
                        :skipped 0 :fetching nil)
             forge-plugins-github-actions--cache)
    (with-temp-buffer
      (setq-local major-mode 'forge-topics-mode)
      (let ((inhibit-read-only t) root s1 s2)
        (setq root (magit-section :type 'root))
        (oset root start (copy-marker (point-min)))
        (insert "topic one\n")
        (setq s1 (magit-section :type 'topic))
        (oset s1 value t1)
        (oset s1 start (copy-marker 1))
        (insert "topic two\n")
        (setq s2 (magit-section :type 'topic))
        (oset s2 value t2)
        (oset s2 start (copy-marker 11))
        (oset root children (list s1 s2))
        (setq-local magit-root-section root)
        (puthash "T1" t1 forge-plugins-github-actions--pending)
        (puthash "T2" t2 forge-plugins-github-actions--pending)
        (forge-plugins-github-actions--flush)
        ;; Both badges applied, pending drained, no timer left armed.
        (should (string-match-p "topic one (2/2)" (buffer-string)))
        (should (string-match-p "topic two (1/3)" (buffer-string)))
        (should (= 0 (hash-table-count forge-plugins-github-actions--pending)))))))

(ert-deftest forge-plugins-github-actions-test-skipped-neutral-non-blocking ()
  "Skipped and neutral runs count in the denominator but don't block success.
One success, one skipped and one neutral render `(1/3)' in the success face."
  (let* ((topic (forge-pullreq :id "T2" :head-rev "abc"))
         (forge-plugins-github-actions--cache (make-hash-table :test 'equal)))
    (puthash "T2" (list :head-rev "abc" :total 3 :success 1 :failure 0
                        :completed 3 :fetching nil)
             forge-plugins-github-actions--cache)
    (let ((summary (forge-plugins-github-actions--status-summary topic)))
      (should (equal (car summary) "(1/3)"))
      (should (eq (cdr summary) 'forge-plugins-github-actions-success)))))

(ert-deftest forge-plugins-github-actions-test-run-app ()
  "The app accessor returns the nested app alist, or nil when absent."
  (let ((run '((name . "build")
               (app . ((id . 15368)
                       (slug . "github-actions")
                       (name . "GitHub Actions"))))))
    (let ((app (forge-plugins-github-actions--run-app run)))
      (should (equal (alist-get 'slug app) "github-actions"))
      (should (equal (alist-get 'name app) "GitHub Actions"))
      (should (equal (alist-get 'id app) 15368))))
  (should-not (forge-plugins-github-actions--run-app '((name . "build")))))

(ert-deftest forge-plugins-github-actions-test-clear-queue ()
  "Clearing the queue empties it, cancels the timer and zeroes in-flight."
  (let ((forge-plugins-github-actions--queue (list 'a 'b))
        (forge-plugins-github-actions--inflight 2)
        (forge-plugins-github-actions--dispatch-timer
         (run-with-timer 100 nil #'ignore)))
    (forge-plugins-github-actions-clear-queue)
    (should-not forge-plugins-github-actions--queue)
    (should (= forge-plugins-github-actions--inflight 0))
    (should-not forge-plugins-github-actions--dispatch-timer)))

(provide 'forge-plugins-github-actions-test)
;;; forge-plugins-github-actions-test.el ends here
