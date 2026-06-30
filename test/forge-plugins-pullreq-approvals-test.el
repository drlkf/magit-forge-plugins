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

(provide 'forge-plugins-pullreq-approvals-test)
;;; forge-plugins-pullreq-approvals-test.el ends here
