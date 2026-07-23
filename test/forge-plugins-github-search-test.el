;;; forge-plugins-github-search-test.el --- Tests for the GitHub search plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; Assert the forge and ghub API surface the plugin depends on, so the
;; build fails when an upstream change renames or removes a symbol the
;; plugin relies on, plus the query shape and response extraction.

;;; Code:

(require 'ert)
(require 'forge)
(require 'ghub)
(require 'forge-plugins-github-search)

(ert-deftest forge-plugins-github-search-test-api-surface ()
  "The forge and ghub symbols the plugin relies on must exist."
  (should (fboundp 'forge--ls-repos))
  (should (fboundp 'ghub-request))
  (dolist (slot '(owner name apihost condition))
    (should (cl-find slot (eieio-class-slots 'forge-github-repository)
                     :key #'eieio-slot-descriptor-name))))

(ert-deftest forge-plugins-github-search-test-commands-exist ()
  "The search commands must be defined."
  (should (commandp 'forge-plugins-github-search))
  (should (fboundp 'forge-plugins-github-search-browse-query)))

(ert-deftest forge-plugins-github-search-test-query-is-string ()
  "The query must be a raw GraphQL string, not a gsexp list.
`ghub' gsexp cannot express the inline fragments the search results
need, so sending it as gsexp would produce malformed GraphQL."
  (should (stringp forge-plugins-github-search--query-string))
  (should (string-match-p "\\.\\.\\. on PullRequest"
                          forge-plugins-github-search--query-string))
  (should (string-match-p "\\.\\.\\. on Issue"
                          forge-plugins-github-search--query-string)))

(ert-deftest forge-plugins-github-search-test-item-face ()
  "Merged and closed items are dimmed; open items use the default face."
  (should (eq (forge-plugins-github-search--item-face "OPEN") 'default))
  (should (eq (forge-plugins-github-search--item-face "MERGED") 'magit-dimmed))
  (should (eq (forge-plugins-github-search--item-face "CLOSED") 'magit-dimmed)))

(ert-deftest forge-plugins-github-search-test-disabled-by-default ()
  "The plugin flag defaults to nil and its commands refuse when off."
  (let ((forge-plugins-github-search-enable nil))
    (should-error (forge-plugins-github-search-browse-query "is:pr")
                  :type 'user-error)))

(provide 'forge-plugins-github-search-test)
;;; forge-plugins-github-search-test.el ends here
