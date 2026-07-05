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
  (should (fboundp 'forge-insert-post))
  (should (boundp 'forge-topic-mode-map))
  (dolist (slot '(owner name apihost))
    (should (cl-find slot (eieio-class-slots 'forge-github-repository)
                     :key #'eieio-slot-descriptor-name)))
  ;; `their-id' is the GraphQL node ID used as the mutation content ID.
  (dolist (class '(forge-issue forge-pullreq))
    (should (cl-find 'their-id (eieio-class-slots class)
                     :key #'eieio-slot-descriptor-name))))

(ert-deftest forge-plugins-github-projects-test-commands-exist ()
  "The topic project commands and their prefix map must be defined."
  (should (commandp 'forge-plugins-github-projects-add))
  (should (commandp 'forge-plugins-github-projects-set-status))
  (should (commandp 'forge-plugins-github-projects-remove))
  (should (keymapp forge-plugins-github-projects-prefix-map)))

(ert-deftest forge-plugins-github-projects-test-queries-are-strings ()
  "Queries must be raw GraphQL strings, not gsexp lists.
`ghub' gsexp cannot express the inline fragments these queries need, so
sending them as gsexp produces malformed GraphQL that GitHub rejects."
  (should (stringp forge-plugins-github-projects--list-query))
  (should (stringp forge-plugins-github-projects--items-query))
  (should (stringp forge-plugins-github-projects--membership-query-template))
  ;; The membership template carries the inline fragment that broke gsexp.
  (should (string-match-p "\\.\\.\\. on ProjectV2ItemFieldSingleSelectValue"
                          forge-plugins-github-projects--membership-query-template))
  (should (string-match-p "pullRequest"
                          (forge-plugins-github-projects--membership-query nil))))

(ert-deftest forge-plugins-github-projects-test-disabled-by-default ()
  "The plugin flag defaults to nil and its command refuses when off."
  (let ((forge-plugins-github-projects-enable nil))
    (should-error (forge-plugins-github-projects) :type 'user-error)))

(provide 'forge-plugins-github-projects-test)
;;; forge-plugins-github-projects-test.el ends here
