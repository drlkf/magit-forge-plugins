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

(provide 'forge-plugins-github-actions-test)
;;; forge-plugins-github-actions-test.el ends here
