;;; forge-plugins-github-projects-test.el --- Tests for the GitHub Projects plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; Assert the forge and ghub API surface the plugin depends on, so the
;; build fails when an upstream change renames or removes a symbol or
;; slot the plugin relies on.

;;; Code:

(require 'ert)
(require 'forge)
(require 'ghub)
(require 'forge-plugins-github-projects)

(ert-deftest forge-plugins-github-projects-test-api-surface ()
  "The forge and ghub symbols and slots the plugin relies on must exist."
  (should (fboundp 'forge-get-repository))
  (should (fboundp 'ghub-query))
  (dolist (slot '(owner name apihost))
    (should (cl-find slot (eieio-class-slots 'forge-github-repository)
                     :key #'eieio-slot-descriptor-name))))

(ert-deftest forge-plugins-github-projects-test-disabled-by-default ()
  "The plugin flag defaults to nil and its command refuses when off."
  (let ((forge-plugins-github-projects-enable nil))
    (should-error (forge-plugins-github-projects) :type 'user-error)))

(provide 'forge-plugins-github-projects-test)
;;; forge-plugins-github-projects-test.el ends here
