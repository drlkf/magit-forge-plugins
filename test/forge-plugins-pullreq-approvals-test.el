;;; forge-plugins-pullreq-approvals-test.el --- Tests for the approvals plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; Assert the forge API surface the plugin depends on, and that the
;; in-place badge patching is idempotent.

;;; Code:

(require 'ert)
(require 'forge)
(require 'forge-pullreq)
(require 'forge-plugins-pullreq-approvals)

(ert-deftest forge-plugins-pullreq-approvals-test-forge-api-surface ()
  "The forge symbols and slots the plugin relies on must exist."
  (should (fboundp 'forge--format-topic-line))
  (should (fboundp 'forge-insert-post))
  (should (fboundp 'forge--rest))
  (should (macrop 'forge-rest))
  (should (cl-find 'head-rev (eieio-class-slots 'forge-pullreq)
                   :key #'eieio-slot-descriptor-name)))

(ert-deftest forge-plugins-pullreq-approvals-test-patch-line-idempotent ()
  "Patching a topic line twice replaces the badge, never duplicates it."
  (let* ((topic (forge-pullreq :id "T1" :head-rev "abc"))
         (forge-plugins-pullreq-approvals--cache (make-hash-table :test 'equal)))
    (puthash "T1" (list :head-rev "abc" :approved 1 :required 2
                        :reviews nil :fetching nil)
             forge-plugins-pullreq-approvals--cache)
    (with-temp-buffer
      (insert "topic line\n")
      (let ((section (magit-section :type 'topic)))
        (oset section value topic)
        (oset section start (copy-marker (point-min)))
        (forge-plugins-pullreq-approvals--patch-line-badge section topic)
        (goto-char (point-min))
        (should (re-search-forward "<1/2>" (line-end-position) t))
        (let ((after-first (buffer-string)))
          (forge-plugins-pullreq-approvals--patch-line-badge section topic)
          (should (equal (buffer-string) after-first))
          (goto-char (point-min))
          (should-not (re-search-forward "<1/2>.*<1/2>" nil t)))))))

(ert-deftest forge-plugins-pullreq-approvals-test-flush-batches ()
  "A single flush patches every pending topic in one tree walk."
  (let* ((t1 (forge-pullreq :id "T1" :head-rev "a"))
         (t2 (forge-pullreq :id "T2" :head-rev "b"))
         (forge-plugins-pullreq-approvals--cache (make-hash-table :test 'equal))
         (forge-plugins-pullreq-approvals--pending (make-hash-table :test 'equal))
         (forge-plugins-pullreq-approvals--flush-timer nil))
    (puthash "T1" (list :head-rev "a" :approved 2 :required 2
                        :reviews nil :fetching nil)
             forge-plugins-pullreq-approvals--cache)
    (puthash "T2" (list :head-rev "b" :approved 1 :required 3
                        :reviews nil :fetching nil)
             forge-plugins-pullreq-approvals--cache)
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
        (puthash "T1" t1 forge-plugins-pullreq-approvals--pending)
        (puthash "T2" t2 forge-plugins-pullreq-approvals--pending)
        (forge-plugins-pullreq-approvals--flush)
        (should (string-match-p "topic one <2/2>" (buffer-string)))
        (should (string-match-p "topic two <1/3>" (buffer-string)))
        (should (= 0 (hash-table-count
                      forge-plugins-pullreq-approvals--pending)))))))

(ert-deftest forge-plugins-pullreq-approvals-test-clear-queue ()
  "Clearing the queue empties it, cancels the timer and zeroes in-flight."
  (let ((forge-plugins-pullreq-approvals--queue (list 'a 'b))
        (forge-plugins-pullreq-approvals--inflight 2)
        (forge-plugins-pullreq-approvals--dispatch-timer
         (run-with-timer 100 nil #'ignore)))
    (forge-plugins-pullreq-approvals-clear-queue)
    (should-not forge-plugins-pullreq-approvals--queue)
    (should (= forge-plugins-pullreq-approvals--inflight 0))
    (should-not forge-plugins-pullreq-approvals--dispatch-timer)))

(provide 'forge-plugins-pullreq-approvals-test)
;;; forge-plugins-pullreq-approvals-test.el ends here
