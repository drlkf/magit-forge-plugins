;;; forge-plugins-github-actions-test.el --- Tests for the GitHub Actions plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; Assert the forge API surface the plugin depends on, so the build fails
;; when an upstream forge change renames or removes a symbol or slot.

;;; Code:

(require 'ert)
(require 'forge)
(require 'forge-pullreq)
(require 'forge-plugins-github-actions)

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

(provide 'forge-plugins-github-actions-test)
;;; forge-plugins-github-actions-test.el ends here
